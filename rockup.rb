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
		@volume = {}; @volume.default_proc = proc {|hash, key| hash[key] = Volume.new(self, key)}
		@source = {}
		sources.each do |d|
			s = Source.new(self, d)
			source[s.id] = s
		end
	end

	def backup!
		if File.directory?(destination)
			@manifest = Manifest.new(self, manifests.sort.first)
		else
			FileUtils.mkdir(destination)
			@manifest = Manifest.new(self)
		end
		volume.each_value {|v| v.store!}
		manifest.store!
	end

	# Find all manifest files in the destination
	def manifests
		Dir[File.join(destination, Manifest::Glob)]
	end

end # Project


class Source

	attr_reader :id, :directory

	def initialize(project, directory, id = nil)
		@project = project
		@directory = directory
		@id = id.nil? ? Base64.encode64(Zlib.crc32(directory).to_s)[0..-4] : id
	end

end # Source


class Volume

	attr_reader :project

	def modified?; @modified end

	def initialize(project, file = nil)
		@project = project
		@modified = false
		if file.nil?
			@new = true
			@file = File.join(project.destination, "#{Time.now.to_i}")
		else
			@file = File.join(project.destination, file)
			raise 'Volume does not exist' unless File.directory?(@file)
		end
	end

	def store!
		if modified?
			raise 'Refuse to overwrite existing volume' if @new && File.exist?(@file)
			begin
			rescue
				FileUtils.rm_rf(@file)
				raise
			end
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
		@file = file
		if @file.nil?
			@modified = true
			@state = {
				'version' => Version,
				'session' => SecureRandom.uuid,
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

	def store!(force = false)
		if modified? || force
			time = @state['stamp'] = Time.now
			@file = "#{time.to_i}.yaml"
			path = File.join(project.destination, @file)
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


p = Rockup::Project.new(['src'], 'dst')
puts p.backup!
