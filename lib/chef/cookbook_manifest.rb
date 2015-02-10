# Author:: Daniel DeLeo (<dan@chef.io>)
# Copyright:: Copyright 2015 Opscode, Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'forwardable'
require 'chef/util/path_helper'
require 'chef/log'

class Chef

  # Handles the details of representing a cookbook in JSON form for uploading
  # to a Chef Server.
  class CookbookManifest

    # TODO: duplicates the same constant in CookbookVersion
    COOKBOOK_SEGMENTS = [ :resources, :providers, :recipes, :definitions, :libraries, :attributes, :files, :templates, :root_files ].freeze

    extend Forwardable

    attr_reader :cookbook_version

    def_delegator :@cookbook_version, :root_paths
    def_delegator :@cookbook_version, :segment_filenames
    def_delegator :@cookbook_version, :name
    def_delegator :@cookbook_version, :metadata
    def_delegator :@cookbook_version, :full_name
    def_delegator :@cookbook_version, :version
    def_delegator :@cookbook_version, :frozen_version?

    # Create a new CookbookManifest object for the given `cookbook_version`.
    # You can subsequently call #to_hash to get a Hash representation of the
    # cookbook_version in the "manifest" format, or #to_json to get a JSON
    # representation of the cookbook_version.
    #
    # @param policy_mode [Boolean] whether to convert cookbooks to Hash/JSON in
    #   the format used by the `cookbook_artifacts` endpoint (for policyfiles).
    #   Setting this option also changes the behavior of #save_url and
    #   #force_save_url such that CookbookVersions will be uploaded to the new
    #   `cookbook_artifacts` API. This endpoint is currently under active
    #   development and the format is expected to change frequently, therefore
    #   the result of #manifest, #to_hash, and #to_json will not be stable when
    #   `policy_mode` is enabled.
    def initialize(cookbook_version, policy_mode: false)
      @cookbook_version = cookbook_version
      @policy_mode = !!policy_mode

      reset!
    end

    # Resets all lazily computed values.
    def reset!
      @manifest = nil
      @checksums = nil
      @manifest_records_by_path = nil
      true
    end

    # Returns a 'manifest' data structure that can be uploaded to a Chef
    # Server.
    #
    # The format is as follows:
    #
    #     {
    #       :cookbook_name  => name,            # String
    #       :metadata       => metadata,        # Chef::Cookbook::Metadata
    #       :version        => version,         # Chef::Version
    #       :name           => full_name,       # String of "#{name}-#{version}"
    #
    #       :recipes        => Array<FileSpec>,
    #       :definitions    => Array<FileSpec>,
    #       :libraries      => Array<FileSpec>,
    #       :attributes     => Array<FileSpec>,
    #       :files          => Array<FileSpec>,
    #       :templates      => Array<FileSpec>,
    #       :resources      => Array<FileSpec>,
    #       :providers      => Array<FileSpec>,
    #       :root_files     => Array<FileSpec>
    #     }
    #
    # Where a `FileSpec` is a Hash of the form:
    #
    #     {
    #       :name         => file_name,
    #       :path         => path,
    #       :checksum     => csum,
    #       :specificity  => specificity
    #     }
    #
    def manifest
      @manifest || generate_manifest
      @manifest
    end

    def checksums
      @manifest || generate_manifest
      @checksums
    end

    def manifest_records_by_path
      @manifest || generate_manifest
      @manifest_records_by_path
    end

    def policy_mode?
      @policy_mode
    end

    def to_hash
      result = manifest.dup
      result['frozen?'] = frozen_version?
      result['chef_type'] = 'cookbook_version'
      result.to_hash
    end

    def to_json(*a)
      result = to_hash
      result['json_class'] = "Chef::CookbookVersion"
      Chef::JSONCompat.to_json(result, *a)
    end

    # Return the URL to save (PUT) this object to the server via the
    # REST api. If there is an existing document on the server and it
    # is marked frozen, a PUT will result in a 409 Conflict.
    def save_url
      "#{cookbook_url_path}/#{name}/#{version}"
    end

    # Adds the `force=true` parameter to the upload URL. This allows
    # the user to overwrite a frozen cookbook (a PUT against the
    # normal #save_url raises a 409 Conflict in this case).
    def force_save_url
      "#{cookbook_url_path}/#{name}/#{version}?force=true"
    end

    # TODO: This is kind of terrible. investigate removing it
    def update_from(new_manifest)
      @manifest = Mash.new new_manifest
      @checksums = extract_checksums_from_manifest(@manifest)
      @manifest_records_by_path = extract_manifest_records_by_path(@manifest)

      # TODO: this part of this method is "feature envious" it only deals with
      # mutating the CookbookVersion object.
      COOKBOOK_SEGMENTS.each do |segment|
        next unless @manifest.has_key?(segment)
        filenames = @manifest[segment].map{|manifest_record| manifest_record['name']}

        cookbook_version.replace_segment_filenames(segment, filenames)
      end
    end

    private

    def cookbook_url_path
      policy_mode? ? "cookbook_artifacts" : "cookbooks"
    end

    # See #manifest for a description of the manifest return value.
    # See #preferred_manifest_record for a description an individual manifest record.
    def generate_manifest
      manifest = Mash.new({
        :recipes => Array.new,
        :definitions => Array.new,
        :libraries => Array.new,
        :attributes => Array.new,
        :files => Array.new,
        :templates => Array.new,
        :resources => Array.new,
        :providers => Array.new,
        :root_files => Array.new
      })
      @checksums = {}

      if !root_paths || root_paths.size == 0
        Chef::Log.error("Cookbook #{name} does not have root_paths! Cannot generate manifest.")
        raise "Cookbook #{name} does not have root_paths! Cannot generate manifest."
      end

      COOKBOOK_SEGMENTS.each do |segment|
        segment_filenames(segment).each do |segment_file|
          next if File.directory?(segment_file)

          path, specificity = parse_segment_file_from_root_paths(segment, segment_file)
          file_name = File.basename(path)

          csum = checksum_cookbook_file(segment_file)
          @checksums[csum] = segment_file
          rs = Mash.new({
            :name => file_name,
            :path => path,
            :checksum => csum,
            :specificity => specificity
          })

          manifest[segment] << rs
        end
      end

      manifest[:cookbook_name] = name.to_s
      manifest[:metadata] = metadata
      manifest[:version] = metadata.version
      manifest[:name] = full_name

      @manifest_records_by_path = extract_manifest_records_by_path(manifest)
      @manifest = manifest
    end

    def parse_segment_file_from_root_paths(segment, segment_file)
      root_paths.each do |root_path|
        pathname = Chef::Util::PathHelper.relative_path_from(root_path, segment_file)

        parts = pathname.each_filename.take(2)
        # Check if path is actually under root_path
        next if parts[0] == '..'
        if segment == :templates || segment == :files
          # Check if pathname looks like files/foo or templates/foo (unscoped)
          if pathname.each_filename.to_a.length == 2
            # Use root_default in case the same path exists at root_default and default
            return [ pathname.to_s, 'root_default' ]
          else
            return [ pathname.to_s, parts[1] ]
          end
        else
          return [ pathname.to_s, 'default' ]
        end
      end
      Chef::Log.error("Cookbook file #{segment_file} not under cookbook root paths #{root_paths.inspect}.")
      raise "Cookbook file #{segment_file} not under cookbook root paths #{root_paths.inspect}."
    end

    def extract_checksums_from_manifest(manifest)
      checksums = {}
      COOKBOOK_SEGMENTS.each do |segment|
        next unless manifest.has_key?(segment)
        manifest[segment].each do |manifest_record|
          checksums[manifest_record[:checksum]] = nil
        end
      end
      checksums
    end

    # TODO: delegating to a class method like this is ugly. We should be able
    # to fix this by moving logic into a class in a way that will make it easy
    # to add support for SHA-2
    def checksum_cookbook_file(filepath)
      CookbookVersion.checksum_cookbook_file(filepath)
    end

    def extract_manifest_records_by_path(manifest)
      manifest_records_by_path = {}
      COOKBOOK_SEGMENTS.each do |segment|
        next unless manifest.has_key?(segment)
        manifest[segment].each do |manifest_record|
          manifest_records_by_path[manifest_record[:path]] = manifest_record
        end
      end
      manifest_records_by_path
    end
  end
end
