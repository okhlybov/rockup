require 'yaml'
require 'zlib'
require 'base64'
require 'fileutils'
require 'securerandom'


module Rockup


class Project
end # Project


class Source

	attr_reader :id, :directory

	def initialize(dir, id = nil)
		@directory = dir
		@id = id.nil? ? Base64.encode64(Zlib.crc32(directory).to_s)[0..-4] : id
	end

end # Source


class Volume
end # Volume


class Manifest

	Version = 1

	def modified?; @modified end

	def version; @state['version'] end

	def session; @state['session'] end

	def sources; @state['sources'] end

	def initialize(file = nil)
		@file = file
		if @file.nil?
			@modified = true
			@state = {
				'version' => Version,
				'id' => SecureRandom.uuid,
				'stamp' => Time.now,
				'sources' => {}
			}
		else
			@modified = false
			@state = YAML.load(IO.read(@file))
			raise 'Unsupported manifest version' unless version == Version
			raise 'Missing manifest session ID' if session.nil?
		end
	end

	def store(dir = nil, force = false)
		if modified? or force
			dir = File.dirname(@file) if dir.nil?
			time = @state['stamp'] = Time.now
			@file = "#{time.to_i}.yaml"
			path = File.join(dir, @file)
			raise 'Refuse to overwrite exising manifest' if File.exist?(path)
			begin
				open(path, 'w') do |io|
					io.write(YAML.dump(@state))
				end
			rescue
				FileUtils.rm_rf(path)
				raise
			end
			path
		else
			nil
		end
	end

end # Manifest


end # Rockup


#puts Rockup::Manifest.new.store('.')
