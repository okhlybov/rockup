# frozen_string_literal: true


require 'aocp'
require 'time'
require 'zlib'
require 'yaml'
require 'msgpack'
require 'ostruct'
require 'fileutils'
require 'iop/file'
require 'iop/zlib'
require 'iop/digest'
require 'iop/string'


module Rockup


  class Registry < Hash
    def <<(x)
      self[x.to_s] = x
      self
    end
    def to_ext(mth = __callee__)
      transform_values {|x| x.send(mth)}
    end
    alias to_h to_ext
    alias to_yaml to_ext
  end


  class Project

    class Registry < Rockup::Registry
      def initialize(project)
        super()
        @project = project
      end
      def [](id = nil)
        if id.nil?
          Metadata.new(@project)
        else
          (x = super).nil? ? Metadata.read(@project, id) : x
        end
      end
    end

    attr_reader :repository

    attr_reader :metadata

    def initialize(url)
      @repository = Repository.provider(url)
      @metadata = Registry.new(self)
    end
  end


  class Repository

    def self.provider(url)
      Local.new(url) # TODO
    end

    attr_reader :url

    def initialize(url)
      @url = url
    end

    def metadata
      entries.collect {|x| Metadata.entry2id(x)}.compact
    end
  end


  class Repository::Local < Repository

    include IOP

    attr_reader :root_dir

    def initialize(url)
      super(@root_dir = url)
    end

    def entries
      Dir.entries(root_dir).delete_if { |x| /^\.{1,2}$/ =~ x }
    end

    def reader(entry)
      FileReader.new(File.join(root_dir, entry))
    end

    def writer(entry)
      unless @root_created
        FileUtils.mkdir_p(root_dir)
        @root_created = true
      end
      FileWriter.new(File.join(root_dir, entry))
    end
  end


  class Metadata

    include IOP

    extend AOCP

    attr_reader :project

    attr_reader :sources

    def initialize(project)
      @project = project
      @time = Time.now
      @sources = Registry.new
      @root_s = to_s
      project.metadata << self
    end

    def_ctor :read, :read do |project, id|
      @id = id
      ( project.repository.reader(entry) | GzipDecompressor.new | (packed = StringMerger.new) ).process!
      hash = MessagePack.unpack(packed.to_s)
      initialize(project)
      @readonly = true
      @time = Time.at(hash['ctime'])
      @head_s = hash['head']
      @root_s = hash['root']
      read_sources(hash['sources'])
    end

    def_ctor :adopt, :adopt do |metadata|
      initialize(metadata.project)
      @head_s = metadata.to_s
      @root_s = metadata.root_s
      read_sources(metadata.sources.to_h)
    end

    private def read_sources(hash)
      hash.each {|id, hash| Source.read(self, id, hash)}
    end

    def eql?(other)
      self.class == other.class && to_s == other.to_s
    end

    def hash
      to_s.hash
    end

    def to_ext(mth = __callee__)
      {
        'rockup'     => 0,
        'repository' => project.repository.url,
        'root'       => @root_s,
        'head'       => @head_s,
        'ctime'      => @time.to_i,
        'sources'    => sources.send(mth)
      }.compact
    end

    alias to_h to_ext

    def to_yaml
      to_ext(__callee__).update('ctime' => @time)
    end

    def to_s
      @id ||= (@time.to_f*1000).to_i.to_s(36)
    end

    def write
      raise "refuse to write read-only metadata `#{self}`" if @readonly
      ( StringSplitter.new(MessagePack.pack(to_h)) | GzipCompressor.new | (d = DigestComputer.new(Digest::MD5.new)) | project.repository.writer(entry)).process!
      ( StringSplitter.new("#{d.digest.hexdigest} #{entry}") | GzipCompressor.new | project.repository.writer("#{self}.md5.gz") ).process!
      @readonly = true
    end

    def entry
      @entry ||= "#{self}.meta.gz"
    end

    def self.entry2id(entry)
      /(.*)\.meta.gz$/ =~ entry
      $1
    end

    protected

    attr_reader :root_s
    attr_reader :head_s

  end


  class Source

    extend AOCP

    attr_reader :metadata

    attr_reader :root_dir

    attr_reader :files

    def initialize(metadata, root_dir)
      @metadata = metadata
      @root_dir = root_dir
      @files = Registry.new
      metadata.sources << self
    end

    def_ctor :read, :read do |metadata, id, hash|
      initialize(metadata, id)
      hash['files'].each {|file, hash| File.read(self, file, hash)}
    end

    def eql?(other)
      self.class == other.class && root_dir == other.root_dir
    end

    def hash
      root_dir.hash
    end

    def to_s
      root_dir
    end

    def to_ext(mth = __callee__)
      {
        'files' => files.send(mth)
      }
    end

    alias to_h to_ext

    alias to_yaml to_ext

    def warning(msg)
      puts msg # TODO
    end

    def update
      local_files.each {|f| File.new(self, f)}
      files.keep_if {|k,v| v.live?}
    end

    def local_files(path = nil, files = [])
      Dir.entries(path.nil? ? root_dir : ::File.join(root_dir, path)).each do |entry|
        next if entry == '.' || entry == '..'
        relative = path.nil? ? entry : ::File.join(path, entry)
        full = ::File.join(root_dir, relative)
        if ::File.directory?(full)
          ::File.readable?(full) ? local_files(relative, files) : warning("insufficient permissions to scan directory `#{full}`")
        else
          ::File.readable?(full) ? files << relative : warning("insufficient permissions to read file `#{full}`")
        end
      end
      files
    end

  end


  class Source::File

    extend AOCP

    attr_reader :file

    attr_reader :source

    def live?; @live end

    protected def revive; @live = true end

    def initialize(source, file)
      @source = source
      @file = file
      @live = true
      if (existing = source.files[file]).nil?
        source.files << self
      else
        unless existing.stat.mtime == self.mtime && existing.size == self.size
          source.files << self
        else
          existing.revive
        end
      end
    end

    def_ctor :read, :read do |source, file, hash|
      initialize(source, file)
      @live = false
      @stat = OpenStruct.new(hash)
      stat.mtime = Time.at(stat.mtime)
      @sha256 = DigestStruct.new(hash['sha256'])
    end

    def stat
      @stat ||= File::Stat.new(File.join(source.root_dir, file))
    end

    def sha256
      @sha256 ||= Digest::SHA256.file(File.join(source.root_dir, file))
    end

    def eql?(other)
      self.class == other.class && file == other.file
    end

    def hash
      file.hash
    end

    def to_s
      file
    end

    def to_ext(mth = __callee__)
      hash = {
        'mtime' => stat.mtime.to_i,
        'mode'  => stat.mode,
        'uid'   => stat.uid,
        'gid'   => stat.gid
      }
      unless stat.size.nil? || stat.size.zero?
        hash['size'] = stat.size
        hash['sha256'] = sha256.digest
      end
      hash.compact
    end

    alias to_h to_ext

    def to_yaml
      hash = to_ext(__callee__)
      hash.update('mtime' => stat.mtime, 'mode' => Octal.new(stat.mode))
      hash.update('sha256' => sha256.hexdigest) unless hash['sha256'].nil?
    end

    # @private
    class Octal
      def initialize(value)
        @value = value
      end
      def encode_with(coder)
        coder.scalar = '0'+@value.to_s(8)
        coder.tag = nil
      end
    end

    # @private
    class DigestStruct
      attr_reader :digest
      def hexdigest; @hexdigest ||= @digest.unpack('H*').first end
      def initialize(digest) @digest = digest end
    end

  end


  class Volume

    attr_reader :project

    attr_reader :to_s

    attr_reader :files

  end


  class Volume::Dir < Volume

  end


  class Volume::Cat < Volume

  end


end
