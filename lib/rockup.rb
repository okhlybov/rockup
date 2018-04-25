require 'set'
require 'yaml'
require 'zlib'
require 'fileutils'
require 'securerandom'


# Incremental file backup engine.
module Rockup


# Module version.
Version = '0.1'


# Represents the Rockup project class.
class Project

	# Directory where backups are stored.
	attr_reader :backup_dir

	# Returns a set of Source directory objects attached to project.
	def sources; end

	# Returns a set of Volume objects attached to project.
	def volumes; end

	# Returns a set of Manifest objects attached to project.
	def manifests; end

end # Project


# Represents source directory to back up.
class Source < String

	# Project instance owning this source.
	attr_reader :project

	# Root directory for the files to back up.
	attr_reader :root_dir

	# Represents a file within the Source hierarchy.
	class File < String

		# Source instance owning this file.
		attr_reader :source

		# Modification time of the file.
		attr_reader :mtime

		# Full path to the file.
		attr_reader :file_name
		
		# Returns +true+ if the file actually exists.
		def extsts?; end
		
		# Returns +true+ if the file is worth compressing.
		def compressible?; end

		# Return floating-point value of presumed compression ratio for the +file_name+ as follows: compressed_size == compression_ratio*uncompressed_size.
		# The estimation heuristics is based on the file name analysis.
		def self.compression_ratio(file_name) end

	end # File

end # Source


# Represents a collection of files in the backup destination directory processed at once.
class Volume < String

	# Project instance owning this volume.
	attr_reader :project

	# Returns +true+ if the volume contents has been modified after it has been created or loaded.
	def modified?; end

	# Returns a list of volumes currently residing in the +project+ backup directory.
	# The list contains plain file or directory names stripped of directory components.
	def self.volumes(project) end

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
class Manifest

	# Manifest structure version this class reads and writes.
	Version = 0

	# Project instance owning this manifest.
	attr_reader :project

	# Full file name the manifest has meen read or will be written to.
	attr_reader :file_name

	# Returns +true+ if the manifest contents has been modified after it has been created or loaded.
	def modified?; end

	# Returns a list of manifests currently residing in the +project+ backup directory.
	# The list contains plain file names stripped of directory components.
	def self.manifests(project) end

end # Manifest


end # Rockup