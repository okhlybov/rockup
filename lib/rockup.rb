require 'set'
require 'zlib'
require 'time'
require 'json/ext'
require 'fileutils'
require 'ostruct'
require 'securerandom'


# Incremental file backup engine.
module Rockup


# Module version.
Version = '0.1'


# :nodoc:
class Identity < Hash
	def <<(o) has_key?(o) ? self[o] : self[o] = o end
	def force!(o) delete(o); self << o end
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

	VolumeTypes = Set[:auto, :copy, :cat]

	# Volume type used for back up.
	attr_reader :volume_type

	def volume_type=(type)
		raise 'Unsupported volume type' unless VolumeTypes.include?(type)
		@volume_type = type
	end

	# Allowed stream compression strategies.
	Compression = Set[:auto, :enforce, :disable]

	# Stream compression strategy.
	attr_reader :compression

	# Set the stream compression strategy. Refer to Compression for available options.
	def compression=(strategy)
		raise 'Unsupported compression strategy' unless Compression.include?(strategy)
		@compression = strategy
	end

	# Supported stream compressors.
	Compressor = Set[nil, :gzip]

	CompressorExt = {gzip: '.gz'}

	# Return +true+ when stream name obfuscation is employed.
	def obfuscate?;	@obfuscate end

	def initialize(backup_dir)
		@backup_dir = backup_dir
		@sources = Identity.new
		@volumes = Identity.new
		@manifests = Identity.new
		self.volume_type = :auto
		self.compression = :disable #:auto
		#@obfuscate = true
	end

	# Compute file statistics
	def self.stats(files)
		total_file_size = 0 # Total size of all files
		avg_file_size = 0 # Average file size
		total_stream_size = 0 # Estimated size of all compressed streams
		files.each do |file|
			total_file_size += (size = file.size)
			total_stream_size += file.compressed_size
			avg_file_size += size
		end
		avg_file_size = avg_file_size/files.size
		OpenStruct.new(
			file_count: files.size,
			file_size: total_file_size,
			avg_file_size: avg_file_size,
			stream_size: total_stream_size
		)
	end

	def backup!(srcs, full = false)
		# Load the latest manifest and continue the incremental backup if full backup is not requested
		mf = manifests << Manifest.new(self, full ? nil : Manifest.manifests(self).sort.last)
		# Restore the object tree from the manifest if it has been loaded from file
		mf.upload! unless mf.new?
		# Actualize data loaded from the manifest with current state of the filesystem
		srcs.each { |dir| (sources << Source.new(self, dir)).update! }
		# Select files which have no associated stream and therefore are the subject to back up
		files = []
		sources.each_key do |source|
			source.files.each_key do |file|
				files << file if file.stream.nil? && file.size > 0
			end
		end
		# Determine backup strategy
		copy_files = [] # Files to be copied
		cat_files = [] # Files to be coalesced
		cat_files_thrs = 1024**3 # Coalesced files size threshold
		large_file_thrs = 1024**2 # Large file size threshold
		case volume_type
		when :auto
			# Put large files into separate streams, coalesce small files into single volume
			sorted = files.sort{ |a, b| a.compressed_size <=> b.compressed_size }
			cat_files_size = 0
			while !(file = sorted.shift).nil? && cat_files_size < cat_files_thrs && file.compressed_size < large_file_thrs
				cat_files_size += file.compressed_size
				cat_files << file
			end
			copy_files = sorted
		when :cat
			cat_files = files
		when :copy
			copy_files = files
		else
			raise
		end
		cat_volume = volumes << Cat.new(self) unless cat_files.empty?
		copy_volume = volumes << Copy.new(self) unless copy_files.empty?
		# Commence the filesystem modification
		begin
			copy_files!(copy_files, copy_volume)
			copy_files!(cat_files, cat_volume)
			mf.store!
		rescue
			mf.rollback! rescue nil
			cat_volume.rollback! rescue nil
			copy_volume.rollback! rescue nil
			raise
		end
	end

	private def copy_files!(files, volume)
		files.each do |file|
			rs = open(file.file_path, 'rb')
			ws = volume.stream(file).writer
			begin
				FileUtils.copy_stream(rs, ws)
			ensure
				rs.close
				ws.close
			end
		end
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
		super(id.nil? ? Zlib.crc32(root_dir).to_s(36) : id)
		@project = project
		@root_dir = root_dir
		@files = Identity.new
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
		# Tag all current files as presumably dead
		files.each_value { |f| f.live = false }
		# Scan though the source directory for new/modified files
		each_file do |f|
			f.live = true
			if files.include?(f)
				if files[f].mtime < f.mtime
					files.force!(f) # Remembered file is outdated, replace it
					@modified = true
				else 
					files[f].live = true # Remembered file is still intact, mark it as alive
				end
			else
				files << f
				@modified = true
			end
		end
		# Actually delete files not marked as live after the filesystem scan
		files.delete_if { |f| f.live? ? false : @modified = true }
	end

	# Restore Source state from specified JSON hash +state+.
	def self.from_json(project, id, state)
		source = Source.new(project, state['root'], id)
		state['files'].each do |file_s, state|
			source.files.force!(File.from_json(source, file_s, state))
		end
		source
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

		# Stream which backs up the file.
		attr_reader :stream

		# Returns modification time of the file.
		# The time is rounded to seconds in order to be comparable with the time converted from string representation.
		def mtime; @mtime ||= info.mtime.round end

		# Returns file size.
		def size; info.size end

		# Returns the SHA1 checksum of the file.
		def sha1; @sha1 ||= Digest::SHA1.file(file_path).to_s end

		# Returns full path to the file.
		def file_path; ::File.join(source.root_dir, self) end
		
		# Returns +true+ if the file is worth compressing.
		def compressible?
			size = info.size
			size*File.compression_ratio(self) + 18 + (to_s.size+1) < size # 18 bytes is the minimum GZip overhead
		end

		# Return estimated file size after compression
		def compressed_size
			@compressed_size ||= (size*File.compression_ratio(self)).to_i
		end

		# Create new File instance.
		# +name+ is expected to be relative to Source#root_dir
		def initialize(source, name)
			super(name)
			@source = source
		end

		private def info; @info ||= ::File::Stat.new(file_path) end

		# :nodoc:
		def live=(live) @live = live end

		# :nodoc:
		def live?; @live end

		# Attaches Stream object backing the file.
		def stream=(stream)
			raise 'Stream is already attached' unless @stream.nil?
			@stream = stream
		end

		# Restore File state from specified JSON hash +state+.
		def self.from_json(source, file_name, state)
			file = File.new(source, file_name)
			file.instance_variable_set(:@mtime, Time.parse(state['mtime']))
			file.instance_variable_set(:@size, state['size'])
			file.instance_variable_set(:@sha1, state['sha1'])
			file
		end

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

	def rollback!
		FileUtils.rm_rf(File.join(project.backup_dir, self)) if modified?
	end

	# Returns a set of volumes currently residing in the +project+ backup directory.
	# The set contains plain file or directory names stripped of directory components.
	def self.volumes(project)
		vs = Set.new
		Dir[File.join(project.backup_dir, '*')].each { |f| vs << File.basename(f) unless Volume.type(f).nil? }
		vs
	end

	# Detect the volume type for specified +path+ or +nil+ if volume type is not recognized.
	def self.type(path)
		if File.directory?(path)
			Copy
		elsif File.exist?(path) && /\.cat$/ =~ path
			Cat
		else
			nil
		end
	end

	# Generate new unique ID for the volume.
	# The ID is generated from current time.
	def self.new_id; Manifest.new_id end

	# Returns a Volume instance corresponding to given +id+.
	def self.open(project, id)
		raise 'Unrecognized volume type' if(v = Volume.type(File.join(project.backup_dir, id))).nil?
		v.new(project, id)
	end

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

		# Compressor employed to compress the stream. Refer to Project::Compressor for available options.
		attr_reader :compressor

		protected def compressor=(type)
			raise 'Unsupported compressor' unless Project::Compressor.include?(type)
			@compressor = type
		end

		# Returns +true+ if stream is compressed.
		def compressed?; !@compressor.nil? end

		def initialize(volume, file, name)
			super(name)
			@file = file
			@volume = volume
			self.compressor = case volume.project.compression
				when :auto
					file.compressible? ? :gzip : nil
				when :enforce
					:gzip
				when :disable
					nil
				else
					raise
			end
		end

	end # Stream

end # Volume


# Represents a Volume where each backed file is stored in separate stream file.
# This volume is most suitable for storing large files.
class Copy < Volume

	def initialize(project, id = nil)
		super(project, id.nil? ? Volume.new_id : id, id.nil?)
	end

	def modify!; @modified = true end

	def stream(file) Stream.new(self, file) end

	class Stream < Volume::Stream

		def initialize(volume, file)
			name = if volume.project.obfuscate?
				# TODO ensure that generated name is actually unique
				x = SecureRandom.random_number(2**32).to_s(36)
				File.join(x.slice!(0, 2), x)
			else
				compressed? ? "#{file}#{Project::CompressorExt[compressor]}" : file
			end
			super(volume, file, name)
		end

		# Returns IO object to write the source file to.
		def writer
			if @writer.nil?
				volume.modify!
				full_path = File.join(volume.project.backup_dir, volume, file.source, self)
				raise 'Refuse to overwrite existing stream file' if File.exist?(full_path)
				FileUtils.mkdir_p(File.dirname(full_path))
				@writer = open(full_path, 'wb')
			else
				@writer
			end
		end

	end # Stream

end # Copy


# Represents a Volume with all files coalesced together in a single file in a manner of `cat` utility.
# This volume is most suitable for storing many small files to circumvent file handling overhead.
class Cat < Volume

	def initialize(project, id = nil)
		@index = 0
		super(project, id.nil? ? "#{Volume.new_id}.cat" : id, id.nil?)
	end

	def new_index; @index += 1 end

	def stream(file) Stream.new(self, file) end

	def writer
		if @writer.nil?
			@modified = true
			@writer = open(File.join(project.backup_dir, self), 'wb')
			class << @writer
				def close; end # Have to disable stream closing for shared Cat writer IO since Project#backup! tries to close it after every file copy operation
			end
		end
		@writer
	end

	class Stream < Volume::Stream

		def initialize(volume, file)
			super(volume, file, volume.new_index.to_s)
		end

		# Returns IO object to write the source file to.
		def writer; volume.writer end

	end # Stream

end # Cat


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
		Set.new(::Dir[File.join(project.backup_dir, '*.json.gz')].collect { |f| File.basename(f, '.json.gz') })
	end

	# Generates new unique ID for the manifest.
	# The ID is generated from current time.
	def self.new_id
		(Time.now.to_f*100).to_i.to_s(36) # Millisecond scale is thought to be enough
	end

	# Reads existing manifest from file or create a new one if +id+ is +nil+.
	def initialize(project, id = nil)
		super(Manifest.new_id)
		@new = id.nil?
		@project = project
		if new?
			@session = self.to_s
		else
			read!(File.join(project.backup_dir, "#{id}.json.gz"))
		end
	end

	# Loads manifest from file.
	# Note that this does not automatically updates the project data structures. Refer to #upload! for details.
	private def read!(file_name)
		open(file_name, 'rb') do |io|
			Zlib::GzipReader.wrap(io) do |gz|
				@json = JSON.parse(gz.read)
				raise 'Unsupported manifest version' unless @json['version'] == Version
				raise 'Missing session ID' if (@session = @json['session']).nil?
			end
		end
	end

	# Saves newly created and modified manifest to file.
	def store!
		if modified?
			@file_name = File.join(project.backup_dir, "#{self}.json.gz")
			raise 'Refuse to overwrite existing manifest' unless new? || !File.exist?(@file_name)
			open(@file_name, 'wb') do |io|
				Zlib::GzipWriter.wrap(io) do |gz|
					gz.write(JSON.pretty_generate(self))
				end
			end
		end
	end

	# Reverts the filesystem in case of a failure by deleting newly created manifest.
	def rollback!
		FileUtils.rm_rf(@file_name) if modified?
	end

	# Uploads the state loaded from file into the project's data structures replacing all existing data.
	# Note that uploading does not raise the modification flags for the structures it alters.
	def upload!
		@json['sources'].each do |source_s, state|
			source = project.sources.force!(Source.from_json(project, source_s, state))
		end
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