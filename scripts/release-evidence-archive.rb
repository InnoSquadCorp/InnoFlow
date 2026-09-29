#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "find"
require "rubygems/package"
require "zlib"

# Artifact ZIP transport resets permissions. A nested tar preserves the file
# modes that are part of the evidence digest. Extract only regular files/dirs
# into a new directory; reject links, traversal, special files and duplicates.
module ReleaseEvidenceArchive
  def self.pack(root, archive)
    root = File.realpath(root)
    archive = File.expand_path(archive)
    FileUtils.mkdir_p(File.dirname(archive))
    parent = File.realpath(File.dirname(archive))
    raise "Archive must stay outside evidence" if parent == root || parent.start_with?(root + "/")
    File.open(archive, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      Zlib::GzipWriter.wrap(file) do |gzip|
        Gem::Package::TarWriter.new(gzip) do |tar|
          Find.find(root) do |path|
            next if path == root
            stat = File.lstat(path)
            name = path.delete_prefix(root + "/")
            raise "Unsafe evidence entry" unless stat.file? || stat.directory?
            raise "Unsafe evidence mode" unless (stat.mode & 0o7000).zero?
            if stat.directory?
              tar.mkdir(name, stat.mode & 0o777)
            else
              tar.add_file_simple(name, stat.mode & 0o777, stat.size) do |entry|
                File.open(path, "rb") { |input| IO.copy_stream(input, entry) }
              end
            end
          end
        end
      end
    end
  end

  def self.unpack(archive, destination)
    raise "Archive must be a regular file" unless File.file?(archive) && !File.symlink?(archive)
    raise "Archive destination already exists" if File.exist?(destination) || File.symlink?(destination)
    FileUtils.mkdir_p(destination)
    root = File.realpath(destination)
    seen = {}
    directories = []
    Zlib::GzipReader.open(archive) do |gzip|
      Gem::Package::TarReader.new(gzip) do |tar|
        tar.each do |entry|
          name = entry.full_name
          parts = name.split("/", -1)
          raise "Unsafe archive path" if name.start_with?("/") || parts.any? { |part| part.empty? || %w[. ..].include?(part) } || name.match?(/[\x00-\x1f\x7f]/)
          raise "Duplicate archive path" if seen[name]
          seen[name] = true
          raise "Unsafe archive type" unless entry.file? || entry.directory?
          mode = entry.header.mode
          raise "Unsafe archive mode" unless mode >= 0 && mode <= 0o777
          path = File.join(root, name)
          FileUtils.mkdir_p(File.dirname(path))
          if entry.directory?
            raise "Archive path is not a directory" if File.exist?(path) && !File.directory?(path)
            FileUtils.mkdir_p(path)
            directories << [path, mode]
          else
            File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
              while (chunk = entry.read(1024 * 1024)) && !chunk.empty?
                file.write(chunk)
              end
            end
            File.chmod(mode, path)
          end
        end
      end
    end
    directories.reverse_each { |path, mode| File.chmod(mode, path) }
    raise "Empty evidence archive" if seen.empty?
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    mode, source, destination = ARGV
    raise "Usage: release-evidence-archive.rb pack|unpack <source> <destination>" unless ARGV.length == 3 && %w[pack unpack].include?(mode)
    ReleaseEvidenceArchive.public_send(mode, source, destination)
  rescue StandardError => error
    abort "[release-evidence-archive] #{error.message}"
  end
end
