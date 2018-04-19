require 'set'
require 'yaml'
require 'zlib'
require 'fileutils'
require 'securerandom'


module Rockup


class Project

	attr_reader :source, :volume, :manifest, :destination

	# When true, do not modify the file system in any way (do not create manifests/volumes/directories etc.)
	def dry?; @dry end

	def dry=(arg) @dry = arg end

	def initialize(sources, destination)
		@destination = destination
		@volume = Volume.new(self)
		@source = {}
		sources.each do |dir|
			src = Source.new(self, dir)
			source[src] = src
		end
	end

	def backup!(incremental = true)
		if File.directory?(destination)
			if incremental
				@manifest = Manifest.new(self, Manifest.manifests(destination).sort.last) # By default read the latest created manifest
			else
				@manifest = Manifest.new(self)
			end
		else
			FileUtils.mkdir(destination) unless dry?
			@manifest = Manifest.new(self)
		end
		source.each_value do |source|
			source.files.each do |file|
				manifest_file = manifest.file(file)
				if manifest_file.nil? || manifest_file['mtime'] < file.stat.mtime
					manifest.merge!(file, volume.merge!(file))
				else
					manifest.live!(file) unless manifest_file.nil?
				end

			end
		end
		manifest.purge!
		begin
			volume.store!
			manifest.store!
		rescue
			volume.cleanup!
			manifest.cleanup!
			raise
		end
	end

end # Project


class Source < String

	attr_reader :project, :directory

	def initialize(project, directory, id = nil)
		super(id.nil? ? Zlib.crc32(directory).to_s(16) : id)
		@project = project
		@directory = directory
	end

	def files
		scan(Set.new, directory)
	end

	def encode_with(coder)
		coder.represent_object(nil, to_s)
	end

	# Append all files recursively contained in root into list
	# Stored file names are relative to root
	private def scan(list, root, path = nil)
		Dir.entries(path.nil? ? root : ::File.join(root, path)).each do |entry|
			next if entry == '.' || entry == '..'
			relative = path.nil? ? entry : ::File.join(path, entry)
			full = ::File.join(root, relative)
			if ::File.directory?(full)
				scan(list, root, relative)
			else
				list << File.new(self, relative)
			end
		end
		list
	end

	# Represents single file relative to the source
	class File < String

		attr_reader :source

		def initialize(source, name)
			super(name)
			@source = source
			@path = ::File.join(self.source.directory, self)
		end

		def encode_with(coder)
			coder.represent_map(nil, to_h)
		end

		def to_h
			{to_s => {'size' => stat.size, 'mtime' => stat.mtime, 'sha1' => sha1}}
		end

		def sha1
			@sha1.nil? ? @sha1 = Digest::SHA1.file(@path).to_s : @sha1
		end

		def stat
			@stat.nil? ? @stat = ::File::Stat.new(@path) : @stat
		end

	end # File

end # Source


class Volume < String

	attr_reader :project, :path 

	def modified?; @modified end

	def initialize(project, id = nil)
		@project = project
		@modified = false
		@contents = [] # Array of Stream instances
		# Perform cleanup actions on rollback
		# Note then setting this to true might leave the on-disk data in inconsistent state
		@cleanup = true
		if (@id = id).nil?
			@new = true
			#@id = Time.now.to_i # Preserve integer representation to prevent quotation of the number-like string by YAML emitter
			@id = Time.now.to_i.to_s(16)
			@path = File.join(project.destination, @id)
		else
			@new = false
			@path = File.join(project.destination, @id)
			raise 'Volume does not exist' unless File.directory?(@path)
		end
		super(@id)
	end

	def store!
		if !project.dry? && modified?
			raise 'Refuse to overwrite existing volume' if @new && File.exist?(path)
			begin
				@contents.each do |stream|
					FileUtils.mkdir_p(basedir = File.join(path, File.dirname(stream)))
					FileUtils.cp_r(File.join(stream.file.source.directory, stream.file), File.join(path, stream))
				end
			rescue
				cleanup!
				raise
			end
		end
	end

	# Create and register new Stream instance for the specified Source::File instance
	def merge!(file)
		raise 'Refuse to modify existing volume' unless @new
		@modified = true
		@contents << (stream = Stream.new(self, file))
		stream
	end

	def encode_with(coder)
		coder.represent_object(nil, @id)
	end

	def cleanup!
		FileUtils.rm_rf(@path) if !project.dry? && modified? && @cleanup
	end

	class Stream < String

		attr_reader :volume, :file

		attr_accessor :sha1

		def initialize(volume, file)
			super(file)
			@volume = volume
			@file = file
			super(File.join(file.source, file))
		end

		def encode_with(coder)
			coder.represent_map(nil, to_h)
		end

		def to_h
			{to_s => {'sha1' => sha1, 'volume' => volume}}
		end

		def sha1
			@sha1.nil? ? @sha1 = Digest::SHA1.file(File.join(volume.path, self)).to_s : @sha1 # TODO compute hash on file to stream copying to avoid extra pass though file contents
		end

	end # Stream

end # Volume


class Manifest

	Version = 0

	# Find all manifest files in the destination
	def self.manifests(dir)
		Dir[File.join(dir, '*.yaml.gz')]
	end

	def modified?; @modified end

	def version; @state['version'] end

	def session; @state['session'] end

	def sources; @state['sources'] end

	def file(file)
		sources[file.source]&.[]('files')&.[](file)
	end

	attr_reader :project

	def initialize(project, file = nil)
		@project = project
		@modified = false
		@file = file
		# Perform cleanup actions on rollback
		# Note then setting this to true might leave the on-disk data in inconsistent state
		@cleanup = true
		if @file.nil?
			@state = {
				'version' => Version,
				'session' => SecureRandom.uuid,
				'mtime' => Time.now,
				'sources' => {}
			}
		else
			open(@file, 'r') do |io|
				Zlib::GzipReader.wrap(io) do |gz|
					@state = YAML.load(gz)
				end
			end
			raise 'Unsupported manifest version' unless version == Version
			raise 'Missing manifest session ID' if session.nil?
		end
	end

	def store!
		if modified? && !project.dry?
			time = @state['mtime'] = Time.now
			@file = "#{time.to_i.to_s(16)}.yaml.gz"
			@path = File.join(project.destination, @file)
			raise 'Refuse to overwrite exising manifest' if File.exist?(@path)
			begin
				open(@path, 'w') do |io|
					Zlib::GzipWriter.wrap(io) do |gz|
						gz.write(YAML.dump(@state))
					end
				end
			rescue
				cleanup!
				raise
			end
			@file
		else
			nil
		end
	end

	def merge!(file, stream)
		sources[file.source] = source = {'directory' => file.source.directory, 'files' => {}} if (source = sources[file.source]).nil?
		hash = file.to_h; hash[file].merge!(:live => true, 'stream' => stream)
		source['files'].merge!(hash)
		@modified = true
	end

	# Tag +file+ as live
	def live!(file)
		sources[file.source]['files'][file][:live] = true
	end

	# Forget all files not tagged as live
	def purge!
		sources.each_value do |source|
			@modified = true unless source['files'].reject! {|file, data| !data.delete(:live)}.nil?
		end
	end

	def cleanup!
		FileUtils.rm_rf(@path) if !project.dry? && modified? && @cleanup
	end

end # Manifest


end # Rockup