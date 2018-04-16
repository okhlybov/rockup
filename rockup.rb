require 'yaml'
require 'zlib'
require 'base64'
require 'fileutils'
require 'securerandom'


module Rockup


class Project

	attr_reader :source, :volume, :manifest, :destination

	def initialize(sources, destination)
		@destination = destination
		@volume = Volume.new(self)
		@source = {}
		sources.each do |dir|
			src = Source.new(self, dir)
			source[src.id] = src
		end
	end

	def backup!
		if File.directory?(destination)
			@manifest = Manifest.new(self, manifests.sort.first)
		else
			FileUtils.mkdir(destination)
			@manifest = Manifest.new(self)
		end
		source.each_value do |source|
			source.files.each do |file|
				manifest.merge!(source, file, volume.merge!(source, file))
			end
		end
		begin
			volume.store!
			manifest.store!
		rescue
			volume.cleanup!
			manifest.cleanup!
			raise
		end
	end

	# Find all manifest files in the destination
	def manifests
		Dir[File.join(destination, Manifest::Glob)]
	end

end # Project


class Source

	attr_reader :id, :project, :directory

	def initialize(project, directory, id = nil)
		@project = project
		@directory = directory
		@id = id.nil? ? Base64.encode64(Zlib.crc32(directory).to_s)[0..-4] : id
	end

	def files
		scan([], directory)
	end

	# Append all files recursively contained in root into list
	# Stored file names are relative to root
	private def scan(list, root, path = nil)
		Dir.entries(path.nil? ? root : File.join(root, path)).each do |entry|
			next if entry == '.' || entry == '..'
			relative = path.nil? ? entry : File.join(path, entry)
			full = File.join(root, relative)
			if File.directory?(full)
				scan(list, root, relative)
			else
				list << relative
			end
		end
		list
	end

end # Source


class Volume

	attr_reader :id, :project

	def modified?; @modified end

	def initialize(project, tag = nil)
		@project = project
		@modified = false
		@contents = []
		if tag.nil?
			@new = true
			@id = Time.now.to_i
			@path = File.join(project.destination, id.to_s)
		else
			@new = false
			@id = id
			@path = File.join(project.destination, id.to_s)
			raise 'Volume does not exist' unless File.directory?(@path)
		end
	end

	def store!
		if modified?
			raise 'Refuse to overwrite existing volume' if @new && File.exist?(@path)
			begin
				@contents.each do |stream|
					FileUtils.mkdir_p(basedir = File.join(@path, File.dirname(stream.id)))
					FileUtils.cp_r(File.join(stream.source.directory, stream.file), destfile = File.join(@path, stream.id))
					stream.sha1 = Digest::SHA1.file(destfile).to_s
				end
			rescue
				cleanup!
				raise
			end
		end
	end

	def merge!(source, file)
		raise 'Refuse to modify existing volume' unless @new
		@modified = true
		@contents << (stream = Stream.new(self, source, file))
		stream
	end

	def cleanup!
		FileUtils.rm_rf(@path) if modified?
	end

	class Stream

		attr_reader :id, :volume, :source, :file

		attr_accessor :sha1

		def initialize(volume, source, file)
			@file = file
			@volume = volume
			@source = source
			@id = File.join(source.id, file)
		end

		def from_hash(hash)
			raise 'Expected a single key' unless hash.size == 1
			@id = hash.keys.first
			@sha1 = hash[id]['sha1']
		end

		def to_hash
			{id => {'volume' => volume.id, 'sha1' => sha1}}
		end
	end

end # Volume


class Manifest

	Version = 1

	Glob = '*.yaml'

	def modified?; @modified end

	def version; @state['version'] end

	def session; @state['session'] end

	def sources; @state['sources'] end

	attr_reader :project

	def initialize(project, file = nil)
		@project = project
		@modified = false
		@file = file
		if @file.nil?
			@state = {
				'version' => Version,
				'session' => SecureRandom.uuid,
				'stamp' => Time.now,
				'sources' => {}
			}
		else
			@state = YAML.load(IO.read(@file))
			raise 'Unsupported manifest version' unless version == Version
			raise 'Missing manifest session ID' if session.nil?
		end
	end

	def store!
		if modified?
			time = @state['stamp'] = Time.now
			@file = "#{time.to_i}.yaml"
			@path = File.join(project.destination, @file)
			raise 'Refuse to overwrite exising manifest' if File.exist?(@path)
			begin
				open(@path, 'w') do |io|
					io.write(YAML.dump(@state))
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

	def merge!(source, file, stream)
		sources[source.id] = contents = {'directory' => source.directory, 'files' => {}} if (contents = sources[source.id]).nil?
		contents['files'][file] = {'stream' => stream.to_hash}
		@modified = true
	end

	def cleanup!
		FileUtils.rm_rf(@path) if modified?
	end

end # Manifest


end # Rockup


p = Rockup::Project.new(['src1', 'src2'], 'dst')
p.backup!
