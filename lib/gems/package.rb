# -*- coding: utf-8 -*-
#--
# Copyright (C) 2004 Mauricio Julio Fernández Pradier
# See LICENSE.txt for additional licensing information.
#++

require 'zlib'
require 'gems/security'

class Gems::Package

  class Error < Gems::Error; end

  class FormatError < Error
    attr_reader :path

    def initialize(message, path = nil)
      @path = path

      message << " in #{path}" if path

      super message
    end

  end

  class PathError < Error
    def initialize(destination, destination_dir)
      super "installing into parent path %s of %s is not allowed" %
              [destination, destination_dir]
    end
  end

  class NonSeekableIO < Error; end

  class TooLongFileName < Error; end

  ##
  # Raised when a tar file is corrupt

  class TarInvalidError < Error; end

  ##
  # The files in this package.  This is not the contents of the gem, just the
  # files in the top-level container.

  attr_reader :files

  ##
  # The security policy used for verifying the contents of this package.

  attr_accessor :security_policy

  ##
  # Sets the Gem::Specification to use to build this package.

  attr_writer :spec

  def self.build(spec)
    gem_file = spec.file_name

    package = new gem_file
    package.spec = spec
    package.build

    gem_file
  end

  ##
  # Creates a new Gem::Package for the file at +gem+.
  #
  # If +gem+ is an existing file in the old format a Gem::Package::Old will be
  # returned.

  def self.new(gem)
    return super unless Gems::Package == self
    return super unless File.exist? gem

    start = File.read gem, 20

    return super unless start
    return super unless start.include? 'MD5SUM ='

    Gem::Package::Old.new gem
  end

  ##
  # Creates a new package that will read or write to the file +gem+.

  def initialize(gem) # :notnew:
    @gem   = gem

    @contents = nil
    @digest = Gems::Security::DIGEST_ALGORITHM
    @files = nil
    @security_policy = nil
    @spec = nil
    @signer = nil
  end

  ##
  # Adds the files listed in the packages's Gem::Specification to data.tar.gz
  # and adds this file to the +tar+.

  def add_contents(tar) # :nodoc:
    tar.add_file_signed 'data.tar.gz', 0444, @signer do |io|
      Zlib::GzipWriter.wrap io do |gz_io|
        Gems::Package::TarWriter.new gz_io do |data_tar|
          add_files data_tar
        end
      end
    end
  end

  ##
  # Adds files included the package's Gem::Specification to the +tar+ file

  def add_files(tar) # :nodoc:
    @spec.files.each do |file|
      stat = File.stat file

      tar.add_file_simple file, stat.mode, stat.size do |dst_io|
        open file, 'rb' do |src_io|
          dst_io.write src_io.read 16384 until src_io.eof?
        end
      end
    end
  end

  ##
  # Adds the package's Gem::Specification to the +tar+ file

  def add_metadata(tar) # :nodoc:
    metadata = @spec.to_yaml
    metadata_gz = Gem.gzip metadata

    tar.add_file_signed 'metadata.gz', 0444, @signer do |io|
      io.write metadata_gz
    end
  end

  ##
  # Builds this package based on the specification set by #spec=

  def build
    @spec.validate
    @spec.mark_version

    if @spec.signing_key then
      @signer = Gem::Security::Signer.new @spec.signing_key, @spec.cert_chain
      @spec.signing_key = nil
      @spec.cert_chain = @signer.cert_chain.map { |cert| cert.to_s }
    else
      @signer = Gem::Security::Signer.new nil, nil
      @spec.cert_chain = @signer.cert_chain.map { |cert| cert.to_pem } if
        @signer.cert_chain
    end

    with_destination @gem do |gem_io|
      Gems::Package::TarWriter.new gem_io do |gem|
        add_metadata gem
        add_contents gem
      end
    end

    say <<-EOM
  Successfully built RubyGem
  Name: #{@spec.name}
  Version: #{@spec.version}
  File: #{File.basename @spec.cache_file}
EOM
  ensure
    @signer = nil
  end

  ##
  # A list of file names contained in this gem

  def contents
    return @contents if @contents

    verify unless @spec

    @contents = []

    read_io do |io|
      gem_tar = Gems::Package::TarReader.new io

      gem_tar.each do |entry|
        next unless entry.full_name == 'data.tar.gz'

        open_tar_gz entry do |pkg_tar|
          pkg_tar.each do |contents_entry|
            @contents << contents_entry.full_name
          end
        end

        return @contents
      end
    end
  end

  ##
  # Creates a digest of the TarEntry +entry+ from the digest algorithm set by
  # the security policy.

  def digest entry # :nodoc:
    digester = @digest.new

    digester << entry.read(16384) until entry.eof?

    entry.rewind

    digester
  end

  ##
  # Extracts the files in this package into +destination_dir+

  def extract_files(destination_dir)
    verify unless @spec

    FileUtils.mkdir_p destination_dir

    read_io do |io|
      reader = Gems::Package::TarReader.new io

      reader.each do |entry|
        next unless entry.full_name == 'data.tar.gz'

        extract_tar_gz entry, destination_dir

        return # ignore further entries
      end
    end
  end

  ##
  # Extracts all the files in the gzipped tar archive +io+ into
  # +destination_dir+.
  #
  # If an entry in the archive contains a relative path above
  # +destination_dir+ or an absolute path is encountered an exception is
  # raised.

  def extract_tar_gz(io, destination_dir) # :nodoc:
    open_tar_gz io do |tar|
      tar.each do |entry|
        destination = install_location entry.full_name, destination_dir

        prepare_destination destination

        with_destination destination, entry.header.mode do |out|
          out.write entry.read
          out.fsync rescue nil # for filesystems without fsync(2)
        end
      end
    end
  end

  ##
  # Returns the full path for installing +filename+.
  #
  # If +filename+ is not inside +destination_dir+ an exception is raised.

  def install_location(filename, destination_dir) # :nodoc:
    raise Gems::Package::PathError.new(filename, destination_dir) if
      filename.start_with? '/'

    destination = File.join destination_dir, filename
    destination = File.expand_path destination

    #raise Gem::Package::PathError.new(destination, destination_dir) unless
      #destination.start_with? destination_dir

    destination.untaint
    destination
  end

  ##
  # Loads a Gem::Specification from the TarEntry +entry+

  def load_spec entry # :nodoc:
    case entry.full_name
    when 'metadata' then
      @spec = Gem::Specification.from_yaml entry.read
    when 'metadata.gz' then
      args = [entry]
      args << { :external_encoding => Encoding::UTF_8 } if
        Object.const_defined? :Encoding

      # TODO: Decouple from Rubygems if possible
      Zlib::GzipReader.wrap(*args) do |gzio|
        @spec = Gem::Specification.from_yaml gzio.read
      end
    end
  end

  ##
  # Opens +io+ as a gzipped tar archive

  def open_tar_gz(io) # :nodoc:
    Zlib::GzipReader.wrap io do |gzio|
      tar = Gems::Package::TarReader.new gzio

      yield tar
    end
  end

  ##
  # The spec for this gem.
  #
  # If this is a package for a built gem the spec is loaded from the
  # gem and returned.  If this is a package for a gem being built the provided
  # spec is returned.

  def spec
    verify unless @spec

    @spec
  end

  ##
  # Verifies that this gem:
  #
  # * Contains a valid gem specification
  # * Contains a contents archive
  # * The contents archive is not corrupt
  #
  # After verification the gem specification from the gem is available from
  # #spec

  def verify
    @files     = []
    @spec      = nil

    digests    = {}
    signatures = {}
    checksums  = {}

    read_io do |io|
      reader = Gems::Package::TarReader.new io

      reader.each do |entry|
        file_name = entry.full_name
        @files << file_name

        case file_name
        when /\.sig$/ then
          signatures[$`] = entry.read if @security_policy
          next
        when /\.sum$/ then
          checksums[$`] = entry.read
          next
        else
          digests[file_name] = digest entry
        end

        case file_name
        when /^metadata(.gz)?$/ then
          load_spec entry
        when 'data.tar.gz' then
          verify_gz entry
        end
      end
    end

    unless @spec then
      raise Gems::Package::FormatError.new 'package metadata is missing', @gem
    end

    unless @files.include? 'data.tar.gz' then
      raise Gems::Package::FormatError.new \
              'package content (data.tar.gz) is missing', @gem
    end

    verify_checksums digests, checksums

    @security_policy.verify_signatures @spec, digests, signatures if
      @security_policy

    true
  rescue Errno::ENOENT => e
    raise Gems::Package::FormatError.new e.message
  rescue Gems::Package::TarInvalidError => e
    raise Gems::Package::FormatError.new e.message, @gem
  end

  ##
  # Verifies that +entry+ is a valid gzipped file.

  def verify_gz entry # :nodoc:
    Zlib::GzipReader.wrap entry do |gzio|
      gzio.read 16384 until gzio.eof? # gzip checksum verification
    end
  rescue Zlib::GzipFile::Error => e
    raise Gems::Package::FormatError.new(e.message, entry.full_name)
  end

  ##
  # Verifies the +checksums+ against the +digests+.  This check is not
  # cryptographically secure.  Missing checksums are ignored.

  def verify_checksums digests, checksums # :nodoc:
    checksums.sort.each do |name, checksum|
      digest = digests[name]
      checksum =~ /#{digest.name}\t(.*)/

      unless digest.hexdigest == $1 then
        raise Gems::Package::FormatError.new("checksum mismatch for #{name}",
                                            @gem)
      end
    end
  end

  # abstract the rest of the code from the file system so regular I/O can be used

  def read_io
    if @io
      @io.rewind
      yield @io
      return
    end

    open @gem, 'rb' do |io|
      @io = StringIO.new(io.read, "rb")
      yield @io
    end
  end

  def prepare_destination(destination)
    FileUtils.rm_rf destination
    FileUtils.mkdir_p File.dirname(destination)
  end

  def with_destination(destination, permissions=nil)
    open destination, 'wb', permissions do |out|
      yield out
    end
  end
end

require 'gems/package/digest_io'
require 'gems/package/old'
require 'gems/package/tar_header'
require 'gems/package/tar_reader'
require 'gems/package/tar_reader/entry'
require 'gems/package/tar_writer'

