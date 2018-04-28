require 'set'
require 'zlib'
require 'json/ext'
require 'fileutils'
require 'securerandom'


# Incremental file backup engine.
module Rockup


# Module version.
Version = '0.1'


# :nodoc:
class Identity < Hash
	def <<(o) has_key?(o) ? self[o] : self[o] = o end
	def force(o) delete(o); self << o end
	def to_json(*opts)
		transform_values{ |o| o.to_json(*opts) }.to_json(*opts)
	end
end # 


# Represents the Rockup project class.
class Project

	# Directory where backups are stored.
  attr_reader :backup_dir

	# Set of Source directory objects attached to project.
	attr_reader :sources

	# Set of Volume objects attached to project.
	attr_reader :volumes

	# Set of Manifest objects attached to project.
	attr_reader :manifests

	def initialize(backup_dir)
		@backup_dir = backup_dir
		@sources = Identity.new
		@volumes = Identity.new; @volumes.default_proc = proc { |hash, id| hash << Volume.open(self, id) }
		@manifests = Identity.new
	end

	def backup!(*srcs)
		srcs.each { |src| (sources << Source.new(self, src)).update! }
	end

end # Project


# Represents source directory to back up.
class Source < String

	# Project instance owning this source.
	attr_reader :project

	# Root directory for the files to back up.
	attr_reader :root_dir

	# Files contained within the source #root_dir.
	# Note that this does not automatically reflect changes to the filesystem thus manual #update! call is required.
	attr_reader :files

	# Returns +true+ if #files contents has been modified by any means (#update! call etc.).
	def modified?; @modified end

	# Create new Source instance.
	# Set the source identifier to +id+ if it's not +nil+ otherwise generate new stable identifier reflecting the #root_dir.
	def initialize(project, root_dir, id = nil)
		super(id.nil? ? Zlib.crc32(root_dir).to_s(16) : id)
		@project = project
		@root_dir = root_dir
		@files = Identity.new
	end

	# Restore Source state from specified +hash+.
	def self.from_hash(project, hash)
		Source.new(project, hash['root'])
	end

	# Calls the specified block for each file recursively found in the #root_dir.
	def each_file(path = nil, &block)
		Dir.entries(path.nil? ? root_dir : ::File.join(root_dir, path)).each do |entry|
			next if entry == '.' || entry == '..'
			relative = path.nil? ? entry : ::File.join(path, entry)
			full = ::File.join(root_dir, relative)
			if ::File.directory?(full)
				each_file(relative, &block)
			else
				yield File.new(self, relative)
			end
		end
		nil
	end

	# Update the data in #files with current state of filesystem.
	# This method replaces old entries (with outdated modification times) and deletes non-existent entries.
	def update!
		# Tag current files as presumably dead
		files.each_value { |f| f.live = false }
		# Scan though the source directory for new/modified files
		each_file do |f|
			f.live = true
			if files.include?(f)
				if files[f].mtime < f.mtime
					@modified = true
					files.force(f) # Remembered file is outdated, replace it
				else 
					files[f].live = true # Remembered file is still actual, mark it as alive
				end
			else
				@modified = true
				files << f
			end
		end
		# Actually delete files not marked as live after the filesystem scan
		files.delete_if { |f| f.live? ? false : @modified = true }
	end

	def to_json(*opts)
		{
			root: root_dir,
			files: files
		}
	end

	# Represents a file within the Source hierarchy.
	class File < String

		# Source instance owning this file.
		attr_reader :source

		# Returns modification time of the file.
		def mtime; @mtime ||= info.mtime end

		# Returns file size.
		def size; info.size end

		# Returns the SHA1 checksum of the file.
		def sha1; @sha1 ||= Digest::SHA1.file(file_path).to_s end

		# Returns full path to the file.
		def file_path; ::File.join(source.root_dir, self) end
		
		# Returns +true+ if the file actually exists in the filesystem.
		def extsts?; ::File.exist?(file_path) end
		
		# Returns +true+ if the file is worth compressing.
		def compressible?
			size = info.size
			size*File.compression_ratio(self) + 18 + (to_s.size+1) < size # 18 bytes is the minimum GZip overhead
		end

		# Create new File instance.
		# +file_name+ is expected to be relative to Source#root_dir
		def initialize(source, file_name)
			super(file_name)
			@source = source
		end

		private def info; @info ||= ::File::Stat.new(file_path) end

		# :nodoc:
		def live=(live) @live = live end

		# :nodoc:
		def live?; @live end

		def to_json(*opts)
			{
				size: size,
				mtime: mtime,
				sha1: sha1
			}
		end

		# Return floating-point value of presumed compression ratio for the +file_name+ as follows: compressed_size == compression_ratio*uncompressed_size.
		# The estimation heuristics is based on the file name analysis.
		def self.compression_ratio(file_name)
			case file_name
			when @@packed_exts, @@packed_stems
				1.05
			else
				0.5
			end
		end

		# (non-exhaustive list of) the most widely used packed file format extensions which are not worth compressing

		packed_audio = %w(aac ape flac gsm m4a m4b m4p mp3 mka mogg mpc oga ogg opus ra wma)

		packed_video = %w(3gp 3g2 asf avi flv f4v f4p f4a f4b mkv m4v mp4 mp4v mpg mpeg mp2 mpe mpv m2v nsv ogv ogg ogv rm vc1 vob webm wmv qt)

		packed_image = %w(bpg gif jpeg jpg jfif jp2 j2k jpf jpx jpm mj2 png tif tiff webp)

		packed_archive = %w(7z s7z ace apk arc arj cab cfs dmg jar lzh lha lzx rar war wim zip zipx zpaq zz gz tgz bz2 tbz tbz2 lzma tlz xz txz)

		packed_document = %w(docx docm dotx dotm xlsx xlsm xltx xltm pptx pptm potx potm odt ott ods ots oth odm)

		skip = (packed_audio + packed_video + packed_image + packed_archive + packed_document).join('|')

		# Match files which are presumably not worth compressing
		@@packed_exts = Regexp.new("\\.(#{skip})$", Regexp::IGNORECASE)

		skip = [
			'\.git/objects', # Git compressed objects
		].join('|')

		@@packed_stems = Regexp.new("(#{skip})")

	end # File

end # Source


# Represents a collection of files in the backup destination directory processed at once.
# Note that the volume is either read-only or write-only, but not both.
class Volume < String

	# Project instance owning this volume.
	attr_reader :project

	# Returns +true+ if the volume contents has been modified after it has been created or loaded.
	def modified?; @modified end

	# Returns +true+ if the volume is newly created (does not already exist).
	def new?; @new end

	def initialize(project, id, new)
		super(id)
		@new = new
		@project = project
	end

	# Returns a set of volumes currently residing in the +project+ backup directory.
	# The set contains plain file or directory names stripped of directory components.
	def self.volumes(project)
		vs = Set.new
		::Dir[File.join(project.backup_dir, '*')].each { |f| vs << File.basename(f) unless Volume.type(f).nil? }
		vs
	end

	# Detect the volume type for specified +path+ or +nil+ if volume type is not recognized.
	def self.type(path)
		if File.directory?(path)
			Dir
		elsif File.exist?(path) && /\.cat$/ =~ path
			Cat
		else
			nil
		end
	end

	# Generate new unique ID for the volume.
	# The ID is generated from current time.
	def self.new_id; Manifest.new_id end

	# Returns a Volume instance corresponding to given +path+.
	def self.open(project, id)
		raise 'Unrecognized volume type' if(v = Volume.type(File.join(project.backup_dir, id))).nil?
		v.new(project, id)
	end

	# Represents a Volume where each backed file is stored separetely.
	# This volume is most suitable for storing large files.
	class Dir < Volume

		def initialize(project, id = nil)
			super(project, id.nil? ? Volume.new_id : id, id.nil?)
		end

	end # Dir

	# Represents a Volume with all files concatenated together in a single file in a manner of `cat` utility.
	# This volume is most suitable for storing many small files to circumvent file handling overhead.
	class Cat < Volume

		def initialize(project, id = nil)
			super(project, id.nil? ? "#{Volume.new_id}.cat" : id, id.nil?)
		end

	end # Cat

	# Represents a named entry in the Volume which identifies backed data.
	class Stream < String

		# Volume instance the stream belongs to.
		attr_reader :volume

		# Source::File instance backed up into the stream.
		attr_reader :file

		# String representation of the +SHA1+ signature of the stream contents.
		attr_reader :sha1

		# Modification time of the file backed into the stream.
		attr_reader :mtime

	end # Stream

end # Volume


# Represents the full state of the backup including metadata for all backed up files and associated streams.
class Manifest < String

	# Manifest structure version this class reads and writes.
	Version = 0

	# Project instance owning this manifest.
	attr_reader :project

	# Returns +true+ if the manifest contents has been modified after it has been created or loaded.
	def modified?
		project.sources.each_key { |src| return true if src.modified? }
		false
	end

	# Returns +true+ if the manifest is newly created (does not already exist).
	def new?; @new end

	# Returns a set of manifests currently residing in the +project+ backup directory.
	# The set contains plain file names stripped of directory components.
	def self.manifests(project)
		Set.new(Dir[File.join(project.backup_dir, '*.json.gz')].collect { |f| File.basename(f, '.json.gz') })
	end

	# Generate new unique ID for the manifest.
	# The ID is generated from current time.
	def self.new_id
		(Time.now.to_f*100).to_i.to_s(36) # Millisecond scale should be enough
	end

	# Read existing manifest from file or create a new one.
	def initialize(project, id = nil)
		super(Manifest.new_id)
		@new = id.nil?
		@project = project
		if new?
			@session = self.to_s
		else
			read!(File.join(project.backup_dir, "#{id}.json.gz"))
		end
		@modified = true
	end

	# Load manifest from file.
	private def read!(file_name)
		open(file_name, 'rb') do |io|
			Zlib::GzipReader.wrap(io) do |gz|
				@json = JSON.parse(gz.read)
				raise 'Unsupported manifest version' unless @json['version'] == Version
				raise 'Missing session ID' if (@session = @json['session']).nil?
			end
		end
	end

	# Save newly created and modified manifest to file.
	def store!
		if modified?
			@file_name = File.join(project.backup_dir, "#{self}.json.gz")
			raise 'Refuse to overwrite existing manifest' unless new? || !File.exist?(@file_name)
			begin
				open(@file_name, 'wb') do |io|
					Zlib::GzipWriter.wrap(io) do |gz|
						gz.write(JSON.pretty_generate(self))
					end
				end
			rescue
				rollback! rescue nil
				raise
			end
		end
	end

	# Reverts the filesystem in case of a failure by deleting newly created manifest.
	def rollback!
		FileUtils.rm_rf(@file_name) if modified?
	end

	def to_json(*opts)
		{
			version: Version,
			mtime: Time.now,
			session: @session,
			sources: project.sources
		}.to_json(*opts)
	end

end # Manifest


end # Rockup


p = Rockup::Project.new('dst')
p.backup!('src')

m = Rockup::Manifest.new(p, Rockup::Manifest.manifests(p).sort.first)
m.store!
