# CocoaPods ignores source_files outside the pod root. Prepare one private
# upstream snapshot and one forwarder per translation unit inside generated/.
# CMake applies these same canonical patches, including header changes.
require 'fileutils'
require 'open3'

module PikafishSources
  ENGINE_SOURCES = %w[
    benchmark.cpp bitboard.cpp evaluate.cpp main.cpp misc.cpp movegen.cpp
    movepick.cpp position.cpp search.cpp thread.cpp timeman.cpp tt.cpp
    uci.cpp ucioption.cpp tune.cpp engine.cpp score.cpp memory.cpp
    nnue/nnue_misc.cpp nnue/features/half_ka_v2_hm.cpp nnue/network.cpp
    external/zip.cpp
  ].freeze

  PATCHES = %w[
    0001-rename-main.patch
    0002-embedded-nnue-failure.patch
    0003-android-asset-network.patch
  ].freeze

  def self.generate!(pod_dir)
    package_dir = File.expand_path('..', pod_dir)
    upstream = File.join(package_dir, 'third_party', 'Pikafish', 'src')
    raise "pikafish_uci: missing pinned source at #{upstream}" unless File.file?(File.join(upstream, 'main.cpp'))

    out = File.join(pod_dir, 'generated')
    FileUtils.mkdir_p(out)
    snapshot = File.expand_path('upstream', out)
    source_dir = File.join(snapshot, 'src')
    if File.exist?(source_dir)
      unless File.realpath(source_dir).start_with?(File.realpath(out) + File::SEPARATOR)
        raise 'pikafish_uci: source snapshot escapes generated directory'
      end
      FileUtils.rm_r(source_dir)
    end
    FileUtils.mkdir_p(source_dir)
    FileUtils.cp_r(File.join(upstream, '.'), source_dir)
    Dir.glob(File.join(source_dir, '**', '*.{cpp,h}')).each do |path|
      File.binwrite(path, File.binread(path).gsub("\r\n", "\n"))
    end
    PATCHES.each do |name|
      patch = File.join(package_dir, 'patches', name)
      _, error, status = Open3.capture3('git', "--work-tree=#{snapshot}", '-C', snapshot,
                                      'apply', '--no-index', patch)
      raise "pikafish_uci: cannot apply #{name}: #{error}" unless status.success?
    end

    {
      'main.cpp' => 'int pikafish_main(',
      'nnue/network.h' => 'bool          verify(',
      'nnue/network.cpp' => 'PIKAFISH_NNUE_LOAD_FAILED',
      'misc.cpp' => 'pikafish_asset_open('
    }.each do |relative, marker|
      unless File.read(File.join(source_dir, relative)).include?(marker)
        raise "pikafish_uci: patch was not applied to #{relative}"
      end
    end

    expected = ENGINE_SOURCES.map { |relative| output_name(relative) }
    expected.concat(%w[pikafish_bridge.cpp pikafish_asset_stream.cpp])
    Dir.children(out).each do |entry|
      path = File.join(out, entry)
      FileUtils.rm_f(path) if File.file?(path) && !expected.include?(entry)
    end
    ENGINE_SOURCES.each do |relative|
      write_forwarder(File.join(out, output_name(relative)), File.join(source_dir, relative))
    end
    %w[pikafish_bridge.cpp pikafish_asset_stream.cpp].each do |name|
      write_forwarder(File.join(out, name), File.join(package_dir, 'src', name))
    end
  end

  def self.output_name(relative)
    return 'pikafish_main.cpp' if relative == 'main.cpp'
    return 'pikafish_engine.cpp' if relative == 'engine.cpp'

    relative.tr('/', '__')
  end

  def self.write_forwarder(output_path, real_path)
    raise "pikafish_uci: expected source missing at #{real_path}" unless File.file?(real_path)

    content = "// Generated CocoaPods forwarder; see generate_pikafish_sources.rb.\n" \
              "#include \"#{real_path}\"\n"
    File.write(output_path, content) unless File.exist?(output_path) && File.read(output_path) == content
  end
end
