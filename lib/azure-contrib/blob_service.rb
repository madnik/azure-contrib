# This code requires Ruby 2.0+ ... it's 2014, people

# Make sure the original is included
require 'azure/blob/blob_service'
require 'celluloid'
require 'timeout'

class ::File
  def each_chunk(chunk_size=2**20)
    yield read(chunk_size) until eof?
  end
end

# The maximum size for a block blob is 200 GB, and a block blob can include no more than 50,000 blocks.
  # http://msdn.microsoft.com/en-us/library/azure/ee691964.aspx

class BlockActor
  include Celluloid

  def initialize(service, container, blob, options = {})
    @service, @container, @blob, @options = service, container, blob, options
  end

  def upload(block_id, chunk, retries = 0)
    Timeout::timeout(@options[:timeout] || 30){
      log "Uploading block #{block_id}"
      options = @options.dup
      options[:content_md5] = Base64.strict_encode64(Digest::MD5.digest(chunk))
      content_md5 = @service.create_blob_block(@container, @blob, block_id, chunk, options)
      log "Done uploading block #{block_id} #{content_md5}"
      [block_id, :uncommitted]
    }
  rescue Timeout::Error, Azure::Core::Error => e
    log "Failed to upload #{block_id}: #{e.class} #{e.message}"
    if retries < 5
      log "Retrying upload (#{retries})"
      upload(block_id, chunk, retries += 1)
    else
      log "Complete failure to upload #{retries} retries"
    end
  end

  def log(message)
    puts message
  end
end

module Azure
  module BlobServiceExtensions
    def create_block_blob(container, blob, content_or_filepath, options={})
      chunking = options.delete(:chunking)
      if chunking
        filepath = content_or_filepath
        block_list = upload_chunks(container, blob, filepath, options)

        unless block_list
          puts "EMPTY BLOCKLIST!"
          return false
        end

        puts "Done uploading #{block_list.size} blocks, committing ..."
        options[:blob_content_type] = options[:content_type]
        commit_blob_blocks(container, blob, block_list, options)
        puts "done."
      else
        content = content_or_filepath
        super(container, blob, content, options)
      end
    end

    # The maximum size for a block blob is 200 GB, and a block blob can include no more than 50,000 blocks.
    # http://msdn.microsoft.com/en-us/library/azure/ee691964.aspx
    def upload_chunks(container, blob, filepath, options = {})
      counter = 1
      futures = []
      pool    = BlockActor.pool(size: 10, args: [self, container, blob, options])

      open(filepath, 'rb') do |f|
        f.each_chunk() {|chunk|
          block_id = counter.to_s.rjust(5, '0')
          futures << pool.future.upload(block_id, chunk)
          counter += 1
        }
      end

      block_list = futures.map(&:value)
      pool.terminate
      return block_list
    end
  end

  # Why alias_method chain when Ruby gives you a more reasonable way to do this
  class BlobService
    prepend BlobServiceExtensions
  end
end