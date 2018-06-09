require 'set'
require 'zlib'
require 'time'
require 'digest'
require 'logger'
require 'json/ext'
require 'fileutils'
require 'securerandom'


# Incremental file backup engine.
module Rockup


# Module version.
Version = '0.1.0'


# :nodoc:
module Log
  @@logger = Logger.new(STDOUT)
  @@logger.level = Logger::WARN
  def self.level=(level) @@logger.level = level end
  def self.debug(*args, &block) @@logger.debug(*args, &block) end
  def self.info(*args, &block) @@logger.info(*args, &block) end
  def self.warn(*args, &block) @@logger.warn(*args, &block) end
  def self.error(*args, &block) @@logger.error(*args, &block) end
  def self.fatal(*args, &block) @@logger.fatal(*args, &block); raise(*args) end
end # Log


# :nodoc:
class Identity < Hash
  private def log_reuse(o) Log.debug "reusing existing object `#{o}`" end
  private def log_replace(o) Log.debug "replacing existing object with `#{o}`" end
  def <<(o)
    if has_key?(o)
      log_reuse(o)
      self[o]
    else
      log_replace(o)
      self[o] = o
    end
  end
  def force!(o)
    Log.debug "forced replacement of existing object with `#{o}`"
    delete(o)
    self << o
  end
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
    Log.fatal "unsupported volume type :#{type}" unless VolumeTypes.include?(type)
    @volume_type = type
    Log.debug "volume type set to :#{type}"
  end

  # Allowed stream compression policies.
  Compressions = Set[:auto, :enforce, :disable]

  # Stream compression strategy.
  attr_reader :compression

  # Set the stream compression strategy. Refer to Compression for available options.
  def compression=(policy)
    Log.fatal "unsupported compression policy :#{policy}" unless Compressions.include?(policy)
    @compression = policy
    Log.debug "compression policy set to :#{policy}"
  end

  # Supported stream compressors.
  Compressor = Set[nil, :gzip]

  # :nodoc:
  CompressorExt = {gzip: '.gz'}

  # Return +true+ when stream name obfuscation is employed.
  def obfuscate?; @obfuscate end

  def initialize(backup_dir)
    Log.info 'initializing project'
    @backup_dir = backup_dir
    @sources = Identity.new
    @volumes = Identity.new
    @manifests = Identity.new
    self.volume_type = :auto
    self.compression = :auto
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

  # Performs backup operation of specified source directories.
  # Returns manifest object.
  def backup!(srcs, full = false)
    Log.info 'starting backup'
    Log.fatal "backup directory `#{backup_dir}` does not exist" unless File.directory?(backup_dir)
    # Load the latest manifest and continue the incremental backup if full backup is not requested
    Log.info 'processing manifest'
    mf = manifests << Manifest.new(self, full ? nil : Manifest.manifests(self).sort.last)
    # Restore the object tree from the manifest if it has been loaded from file
    mf.upload! unless mf.new?
    # Actualize data loaded from the manifest with current state of the filesystem
    Log.info 'examining file system state'
    srcs.each do |dir|
      (sources << Source.new(self, dir)).update!
    end
    # Select files which have no associated stream and therefore are the subject to back up
    files = []
    Log.info 'building list of files to back up'
    sources.each_key do |source|
      Log.info "processing source directory `#{source.root_dir}`"
      source.files.each_key do |file|
        Log.debug "examining file `#{file}`"
        if file.stream.nil? && file.size > 0
          Log.info "registering file `#{file}` for back up"
          files << file
        end
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
      Log.info 'sorting file list'
      sorted = files.sort { |a, b| a.compressed_size <=> b.compressed_size } # Small files come first
      cat_files_size = 0
      Log.info 'determining files destination'
      while !(file = sorted.shift).nil? && cat_files_size < cat_files_thrs && file.compressed_size < large_file_thrs
        cat_files_size += file.compressed_size
        cat_files << file
      end
      sorted.unshift(file) unless file.nil?
      copy_files = sorted
      copy_files << cat_files.shift if cat_files.size == 1
    when :cat
      cat_files = files
    when :copy
      copy_files = files
    else
      raise
    end
    cat_volume = volumes << Cat.new(self)
    copy_volume = volumes << Copy.new(self)
    # Commence the filesystem modification
    begin
      Log.info 'copying files'
      copy_files!(copy_files, copy_volume)
      copy_volume.store!
      Log.info 'coalescing files'
      copy_files!(cat_files, cat_volume)
      cat_volume.store!
      mf.store!
      Log.fatal 'pristine manifest & modified volume(s)' if $DEBUG && (cat_volume.modified? || copy_volume.modified?) && !mf.modified?
    rescue
      Log.error 'backup failure, rolling back'
      mf.rollback! rescue Log.error 'manifest rollback failure'
      cat_volume.rollback! rescue Log.error 'cat volume rollback failure'
      copy_volume.rollback! rescue Log.error 'copy volume rollback failure'
      raise
    end
    Log.info 'no changes detected' unless cat_volume.modified? || copy_volume.modified? || mf.modified?
    Log.info 'backup finished'
    mf
  end

  private def copy_files!(files, volume)
    files.each do |file|
      Log.debug "copying file `#{file}`"
      rs = open(file.file_path, 'rb')
      file.stream = volume.stream(file)
      ws = file.stream.writer
      begin
        FileUtils.copy_stream(rs, ws)
      ensure
        rs.close
        ws.close
      end
    end
  end

  # Preforms restoring backed files into empty the directory +dst+.
  def restore!(dst)
    Log.info 'starting restoration'
    if File.directory?(dst)
      Log.info "destination directory `#{dst}` already exists; reusing"
    else
      FileUtils.mkdir_p(dst) rescue Log.fatal "failed to create destination directory `#{dst}`"
    end
    Log.fatal "refuse to restore to a non-empty directory `#{dst}`" unless Dir.empty?(dst)
    Log.info 'processing manifest'
    mf = manifests << Manifest.new(self, Manifest.manifests(self).sort.last)
    mf.upload!
    sources.each_key do |source|
      Log.info "processing source directory `#{source.root_dir}`"
      dir = File.join(dst, source)
      Log.info "creating destination directory #{dir}"
      FileUtils.mkdir_p(dir)
      source.files.each_key do |file|
        Log.info "restoring file `#{file}`"
        file_path = File.join(dir, file)
        FileUtils.mkdir_p(File.dirname(file_path))
        if file.size > 0
          Log.fatal "file #{file} has no stream attached" if $DEBUG && file.stream.nil?
          rs = file.stream.reader
          ws = open(file_path, 'wb')
          begin
            copied = false
            begin
              FileUtils.copy_stream(rs, ws)
              copied = true
            ensure
              rs.close
              ws.close
            end
            if copied && Digest::SHA1.file(file_path).to_s == file.sha1
              Log.info("checksum verification passed for file `#{file_path}`")
            else
              Log.fatal("checksum verification failed for file `#{file_path}`")
            end
          rescue
            unless $DEBUG
              Log.error("removing corrupted file `#{file_path}`")
              FileUtils.rm_rf(file_path)
            end
            raise
          end
        else
          Log.debug "touching zero-size file `#{file}`"
          FileUtils.touch(file_path)
        end
      end
    end
    Log.info 'restoration finished'
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
    Log.debug "creating source `#{id}` for root `#{root_dir}`"
    super(id.nil? ? Zlib.crc32(root_dir).to_s(36) : id)
    @project = project
    @root_dir = root_dir
    @files = Identity.new
    @modified = false
  end

  # Calls the specified block for each file recursively found in the #root_dir.
  def each_file(path = nil, &block)
    Dir.entries(path.nil? ? root_dir : ::File.join(root_dir, path)).each do |entry|
      next if entry == '.' || entry == '..'
      relative = path.nil? ? entry : ::File.join(path, entry)
      full = ::File.join(root_dir, relative)
      if ::File.directory?(full)
        ::File.readable?(full) ? each_file(relative, &block) : Log.warn("insufficient permissions to scan directory `#{full}`; skipping")
      else
        ::File.readable?(full) ? yield(File.new(self, relative)) : Log.warn("insufficient permissions to read file `#{full}`; skipping")
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
      Log.info "processing existing file `#{f}`"
      f.live = true
      if files.include?(f)
        _f = files[f]
        Log.info "file #{f} is already registered"
        if _f.mtime < f.mtime
          Log.info "registered file `#{f}` has outdated modification time"
          files.force!(f) # Remembered file is outdated, replace it
          @modified = true
        else
          unless _f.meta_equal?(f)
            Log.info "meta information for file `#{f}` has changed"
            _f.meta_borrow!(f)
            @modified = true
          else
            Log.info "file #{f} has not changed since last backup"
          end
          _f.live = true # Remembered file is still intact, mark it as alive
        end
      else
        Log.info "registering new file `#{f}`"
        files << f
        @modified = true
      end
      Log.debug(f.stream.nil? ? "file #{f} has no attached stream" : "file #{f} has stream `#{f.stream}` attached")
    end
    # Actually delete files not marked as live after the filesystem scan
    files.delete_if { |f| f.live? ? false : @modified = true }
  end

  # Restore Source state from specified JSON hash +state+.
  def self.from_json(project, id, state)
    Log.info "reading source `#{id}` from JSON state"
    source = project.sources << Source.new(project, state['root'], id)
    state['files'].each do |file_s, s|
      source.files.force!(File.from_json(source, file_s, s))
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
    def size; @size ||= info.size end

    # Returns POSIX permissions mode.
    def mode; @mode ||= info.mode end

    # Returns POSIX user id.
    def uid; @uid ||= info.uid end

    # Return POSIX group id.
    def gid; @gid ||= info.gid end

    # Borrow metadata (permissions, owner etc.) from source +file+.
    def meta_borrow!(file)
      @mode = file.mode
      @uid = file.uid
      @gid = file.gid
    end

    # Returns true if metadata for +self+ and +file+ are equal.
    def meta_equal?(file)
      mode == file.mode && uid == file.uid && gid == file.gid
    end

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
      @stream = nil
    end

    private def info; @info ||= ::File::Stat.new(file_path) end

    # :nodoc:
    def live=(live) @live = live end

    # :nodoc:
    def live?; @live end

    # Attaches Stream object backing the file.
    def stream=(stream)
      Log.debug "attaching stream `#{stream}` to file `#{self}`"
      Log.fatal 'stream is already attached' unless @stream.nil?
      @stream = stream
    end

    # Restore File state from specified JSON hash +state+.
    def self.from_json(source, file_s, state)
      Log.info "reading file `#{file_s}` from JSON state"
      File.new(source, file_s).from_json(state)
    end

    def from_json(state)
      @uid = state['uid']
      @gid = state['gid']
      @mode = state['mode']
      @mtime = Time.parse(state['mtime'])
      @size = (sz = state['size']).nil? ? 0 : sz
      unless sz.nil?
        @sha1 = state['sha1']
        self.stream = Volume::Stream.from_json(self, state['stream'])
      end
      self
    end

    def to_json(*opts)
      hash = {mtime: mtime, mode: mode, uid: uid, gid: gid}
      # The fields below are meaningful for non-zero files only
      hash.merge!(size: size, sha1: sha1, stream: stream) if size > 0
      hash
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
    @modified = false
  end

  def rollback!
    if modified?
      path = File.join(project.backup_dir, self)
      Log.info "volume `#{self}` is modified, deleting `#{path}`"
      FileUtils.rm_rf(path)
    else
      Log.info "volume `#{self}` is not modified, skipping"
    end
  end

  # Returns compressor for +file+ according to current policy.
  def compressor(file)
    case project.compression
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

  def store!
    Log.info modified? ? "committing the modifications to volume `#{self}`" : "skipping pristine volume `#{self}`"
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
    Log.fatal 'unrecognized volume type' if(v = Volume.type(File.join(project.backup_dir, id))).nil?
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

    # Compressor employed to compress the stream. Refer to Project::Compressor for available options.
    attr_reader :compressor

    # Returns +true+ if stream is compressed.
    def compressed?; !@compressor.nil? end

    def initialize(volume, file, id)
      super(id)
      @file = file
      @volume = volume
      @state = nil
    end

    # Restore Stream state from specified JSON hash +state+.
    def self.from_json(file, state)
      project = file.source.project
      stream = (project.volumes << Volume.open(project, state['volume'])).stream(file)
      stream.from_json!(state)
    end

    def from_json!(state)
    @state = state # Capturing hash for later #to_json
    @compressor = state['compressor'].nil? ? nil : state['compressor'].intern
    self
    end

    # Represents an IO-like class which computes the SHA1 checksum of processed data.
    class SHA1Computer
      attr_reader :sha1
      def initialize(io)
        @sha1 = Digest::SHA1.new
        @io = io
      end
      def read(*args)
        @sha1.update(data = @io.read(*args))
        data
      end
      def write(data)
        @sha1.update(data)
        @io.write(data)
      end
      def close
        @io.close
      end
    end # SHA1Computer

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

    def initialize(volume, file, id = nil)
      if id.nil?
        @compressor = volume.compressor(file)
        id = if volume.project.obfuscate?
          # TODO ensure that generated name is actually unique
          x = SecureRandom.random_number(2**32).to_s(36)
          File.join(x.slice!(0, 2), x)
        else
          ext = Project::CompressorExt[compressor]
          File.join(file.source, ext.nil? ? file : "#{file}#{ext}")
        end
      end
      super(volume, file, id)
    end

    # Returns new IO object to write the source file to.
    def writer
      Log.debug "obtaining a new writer for stream `#{self}`"
      volume.modify!
      full_path = File.join(volume.project.backup_dir, volume, self)
      Log.fatal "refuse to overwrite existing stream file `#{full_path}`" if File.exist?(full_path)
      FileUtils.mkdir_p(File.dirname(full_path))
      @writer = SHA1Computer.new(open(full_path, 'wb'))
      compressed? ? GzipWriter.new(@writer) : @writer
    end

    # Returns new IO object to read the stream file.
    def reader
      Log.debug "obtaining a new reader for stream `#{self}`"
      full_path = File.join(volume.project.backup_dir, volume, self)
      Log.fatal "failed to open stream file `#{full_path}`" if !File.readable?(full_path)
      reader = open(full_path, 'rb')
      compressed? ? Zlib::GzipReader.new(reader) : reader
    end

    def from_json!(state)
      Log.debug "reading JSON state for Copy stream `#{self}`"
      super
    end
    
    def to_json(*opts)
      Log.debug "generating JSON state for Copy stream `#{self}`"
      if @state.nil?
        @state = {'name' => to_s, 'volume' => volume, 'sha1' => @writer.sha1}
        @state['compressor'] = compressor if compressed?
      end
      %w(volume name sha1).each { |k| Log.fatal("missing required key `#{k}`") if @state[k].nil? } if $DEBUG
      @state.to_json(*opts)
    end

    # :nodoc:
    # Auxillary Gzip reader which closes the chained IO when closing self
    class GzipReader < Zlib::GzipReader
      def initialize(io, *opts)
        @chained = io
        super
      end
      def close
        super
        @chained.close
      end
    end # GzipReader

    # :nodoc:
    # Auxillary Gzip writer which closes the chained IO when closing self
    class GzipWriter < Zlib::GzipWriter
      def initialize(io, *opts)
        @chained = io
        super
      end
      def close
        super
        @chained.close
      end
    end # GzipWriter

  end # Stream

end # Copy


# Represents a Volume with all files coalesced together into a single file in a manner of the +cat+ utility.
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
      Log.debug "obtaining a new shared writer for volume `#{self}`"
      @modified = true
      path = File.join(project.backup_dir, self)
      Log.fatal "refuse to overwrite existing file `#{path}`" if File.exist?(path)
      @writer = open(path, 'wb')
      class << @writer
        def close; end # Have to disable stream closing for shared Cat writer IO since Project#backup! tries to close it after every file copy operation
      end
    end
    @writer
  end

  def reader
    if @reader.nil?
      Log.debug "obtaining a new shared reader for volume `#{self}`"
      path = File.join(project.backup_dir, self)
      @reader = open(path, 'rb')
      class << @reader
        def close; end # Have to disable stream closing for shared Cat reader IO since Project#backup! tries to close it after every file copy operation
      end
    end
    @reader
  end

  class Stream < Volume::Stream

    def initialize(volume, file, id = nil)
      super(volume, file, id.nil? ? volume.new_index.to_s : id)
      @compressor = volume.compressor(file) if id.nil?
    end

    # Returns IO object to write the source file to.
    def writer
      Log.debug "obtaining a new writer for stream `#{self}`"
      @writer = Writer.new(volume.writer)
      compressed? ? Zlib::GzipWriter.new(@writer) : @writer
    end

    # Returns IO object to read the source file from.
    def reader
      Log.debug "obtaining a new reader for stream `#{self}`"
      @reader = Reader.new(volume.reader, @offset, @size)
      compressed? ? Zlib::GzipReader.new(@reader) : @reader
    end

    def from_json!(state)
      Log.debug "reading JSON state for Cat stream `#{self}`"
      @offset = state['offset']
      @size = state['size']
      super
    end
    
    def to_json(*opts)
      Log.debug "generating JSON state for Cat stream `#{self}`"
      if @state.nil?
        @state = {'volume' => volume, 'offset' => @writer.offset, 'size' => @writer.size, 'sha1' => @writer.sha1}
        @state['compressor'] = compressor if compressed?
      end
      %w(volume offset size sha1).each { |k| Log.fatal("missing required key `#{k}`") if @state[k].nil? } if $DEBUG
      @state.to_json(*opts)
    end

    # :nodoc:
    class Reader
      def initialize(io, offset, size)
        @io = io
        @io.seek(offset)
        @size = size
      end
      def readpartial(*args)
        @io.readpartial(*args)
      end
      def read
        @io.read(@size)
      end
      def close
        @io.close
      end
    end

    # :nodoc:
    class Writer < SHA1Computer
      attr_reader :size, :offset
      def initialize(*args)
        super
        @offset = @io.pos
        @size = 0
      end
      def write(data)
        super
        @size += data.size
      end
    end # Writer

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
      Log.info "creating new manifest `#{@session}`"
      @session = self.to_s
    else
      read!(File.join(project.backup_dir, "#{id}.json.gz"))
    end
  end

  # Loads manifest from file.
  # Note that this does not automatically updates the project data structures. Refer to #upload! for details.
  private def read!(file_name)
    Log.info "loading manifest from `#{file_name}`"
    open(file_name, 'rb') do |io|
      Zlib::GzipReader.wrap(io) do |gz|
        @json = JSON.parse(gz.read)
        Log.fatal 'unsupported manifest version' unless @json['version'] == Version
        Log.fatal 'missing session ID' if (@session = @json['session']).nil?
      end
    end
  end

  # Saves newly created and modified manifest to file.
  def store!
    if modified?
      Log.info "committing modifications to manifest `#{self}`"
      @file_name = File.join(project.backup_dir, "#{self}.json.gz")
      Log.fatal "refuse to overwrite existing manifest file `#{@file_name}`" unless new? || !File.exist?(@file_name)
      open(@file_name, 'wb') do |io|
        Zlib::GzipWriter.wrap(io) do |gz|
          gz.write(JSON.pretty_generate(self))
        end
      end
    else
      Log.info "skipping pristine manifest `#{self}`"
    end
  end

  # Reverts the filesystem in case of a failure by deleting newly created manifest.
  def rollback!
    if modified?
      Log.info "manifest `#{self}` is modified, deleting `#{@file_name}`"
      FileUtils.rm_rf(@file_name)
    else
      Log.info "manifest `#{self}` is not modified, skipping"
    end
  end

  # Uploads the state loaded from file into the project's data structures replacing all existing data.
  # Note that uploading does not raise the modification flags for the structures it alters.
  def upload!
    Log.info 'uploading manifest contents into project'
    @json['sources'].each do |source_s, state|
      project.sources.force!(Source.from_json(project, source_s, state))
    end
  end

  def to_json(*opts)
    Log.debug "generating JSON state for manifest `#{self}`"
    {
      version: Version,
      mtime: Time.now,
      session: @session,
      sources: project.sources
    }.to_json(*opts)
  end

end # Manifest


end # Rockup