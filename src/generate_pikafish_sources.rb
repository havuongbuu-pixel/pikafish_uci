# Generates, inside the calling podspec's own directory, everything its
# source_files needs to compile the engine.
#
# CocoaPods silently drops any source_files pattern that escapes the pod's own
# root (the podspec's directory) via `../` — it never raises, the file is just
# not compiled, which is what made the first version of these podspecs produce
# an app that linked "successfully" with none of the engine's code in it. This
# is exactly what the vanilla `flutter create --template=plugin_ffi` template
# works around with a `Classes/` forwarder that `#include`s a single file from
# `../src`; this plugin has dozens of translation units (including NNUE and
# Zstandard) instead of one, so this generates one forwarder per file.
#
# main.cpp needs actual text surgery, not just forwarding — Pikafish's own
# main() must become pikafish_main() before anything can link against
# pikafish_bridge.cpp, which calls it by that name — so it is handled
# separately by GeneratedMain, mirroring generate_pikafish_main.cmake exactly:
# read the one-line rename out of patches/0001-rename-main.patch (so there is
# one source of truth for both build systems) rather than hardcoding the
# signature here, and leave the submodule itself untouched.
require 'fileutils'

module PikafishSources
  ENGINE_SOURCES = %w[
    attacks.cpp
    benchmark.cpp
    bitboard.cpp
    evaluate.cpp
    memory.cpp
    misc.cpp
    movegen.cpp
    movepick.cpp
    position.cpp
    score.cpp
    search.cpp
    thread.cpp
    timeman.cpp
    tt.cpp
    tune.cpp
    uci.cpp
    ucioption.cpp
    external/common/debug.cpp
    external/common/entropy_common.cpp
    external/common/error_private.cpp
    external/common/fse_decompress.cpp
    external/common/pool.cpp
    external/common/threading.cpp
    external/common/xxhash.cpp
    external/common/zstd_common.cpp
    external/decompress/huf_decompress.cpp
    external/decompress/huf_decompress_amd64.S
    external/decompress/zstd_ddict.cpp
    external/decompress/zstd_decompress.cpp
    external/decompress/zstd_decompress_block.cpp
    nnue/features/full_threats.cpp
    nnue/features/half_ka_v2_hm.cpp
    nnue/network.cpp
    nnue/nnue_accumulator.cpp
    nnue/nnue_misc.cpp
  ].freeze

  def self.generate!(pod_dir)
    pikafish_src = File.expand_path(File.join(pod_dir, '..', 'third_party', 'Pikafish', 'src'))
    bridge_src = File.expand_path(File.join(pod_dir, '..', 'src', 'pikafish_bridge.cpp'))
    out_dir = File.join(pod_dir, 'generated')
    FileUtils.mkdir_p(out_dir)

    expected = ENGINE_SOURCES.map { |relative| relative.tr('/', '__') }
    expected.concat(%w[pikafish_bridge.cpp pikafish_main.cpp pikafish_engine.cpp])
    Dir.children(out_dir).each do |entry|
      FileUtils.rm_f(File.join(out_dir, entry)) unless expected.include?(entry)
    end

    write_forwarder(File.join(out_dir, 'pikafish_bridge.cpp'), bridge_src)
    ENGINE_SOURCES.each do |relative|
      output_name = relative.tr('/', '__')
      write_forwarder(File.join(out_dir, output_name), File.join(pikafish_src, relative))
    end
    GeneratedMain.generate!(pod_dir, pikafish_src)
    GeneratedEngine.generate!(pod_dir, pikafish_src)
  end

  def self.write_forwarder(output_path, real_path)
    unless File.exist?(real_path)
      raise "pikafish_uci: expected source missing at #{real_path}. " \
            'Run: git submodule update --init --recursive'
    end
    content = "// Generated forwarder so this translation unit lives inside the pod's own\n" \
              "// root, which CocoaPods requires for source_files — see\n" \
              "// generate_pikafish_sources.rb. Compiled as its own unit, matching\n" \
              "// CMakeLists.txt, not merged with any other file.\n" \
              "#include \"#{real_path}\"\n"
    File.write(output_path, content) unless File.exist?(output_path) && File.read(output_path) == content
  end

  module GeneratedMain
    def self.generate!(pod_dir, pikafish_src)
      input_path = File.join(pikafish_src, 'main.cpp')
      patch_path = File.join(pod_dir, '..', 'patches', '0001-rename-main.patch')
      output_path = File.join(pod_dir, 'generated', 'pikafish_main.cpp')

      unless File.exist?(input_path)
        raise "pikafish_uci: official Pikafish sources missing at #{input_path}. " \
              'Run: git submodule update --init --recursive'
      end

      patch_lines = File.readlines(patch_path)
      removed = patch_lines.grep(/^-int main\(/).map { |line| line[1..].chomp }
      added = patch_lines.grep(/^\+int pikafish_main\(/).map { |line| line[1..].chomp }
      unless removed.length == 1 && added.length == 1
        raise 'pikafish_uci: the entry-point patch must contain exactly one ' \
              "removed main() line and one added pikafish_main() line (#{patch_path})"
      end
      old_line = removed.first
      new_line = added.first
      old_definition = "#{old_line}\n"
      new_definition = "#{new_line}\n"

      source = File.read(input_path)
      old_count = source.scan(Regexp.new(Regexp.escape(old_definition))).length
      new_count = source.scan(Regexp.new(Regexp.escape(new_definition))).length

      result =
        if old_count == 1 && new_count.zero?
          source.sub(old_definition, new_definition)
        elsif old_count.zero? && new_count == 1
          # Also accept a tree patched manually by tools/apply_patches.sh.
          source
        else
          raise 'pikafish_uci: main.cpp matches neither side of the published ' \
                "entry-point patch (main=#{old_count}, pikafish_main=#{new_count})"
        end

      File.write(output_path, result) unless File.exist?(output_path) && File.read(output_path) == result
    end
  end

  module GeneratedEngine
    OLD_TEXT = <<~'CPP'.strip.freeze
      void Engine::go(Search::LimitsType& limits) {
          assert(limits.perft == 0);
          verify_network();

          threads.start_thinking(pos, states, limits);
      }
    CPP

    NEW_TEXT = <<~'CPP'.strip.freeze
      void Engine::go(Search::LimitsType& limits) {
          assert(limits.perft == 0);
          const auto evalFile = path_from_utf8(std::string(options["EvalFile"]));
          if (networkFile.current != evalFile)
          {
              if (onVerifyNetwork)
                  onVerifyNetwork("PIKAFISH_NNUE_LOAD_FAILED");
              updateContext.onBestmove("(none)", "");
              return;
          }
          verify_network();

          threads.start_thinking(pos, states, limits);
      }
    CPP

    def self.generate!(pod_dir, pikafish_src)
      input_path = File.join(pikafish_src, 'engine.cpp')
      output_path = File.join(pod_dir, 'generated', 'pikafish_engine.cpp')
      patch_path = File.join(pod_dir, '..', 'patches', '0002-embedded-nnue-failure.patch')

      raise "pikafish_uci: expected patch missing at #{patch_path}" unless File.exist?(patch_path)
      source = File.read(input_path)
      result =
        if source.include?(OLD_TEXT)
          source.sub(OLD_TEXT, NEW_TEXT)
        elsif source.include?(NEW_TEXT)
          source
        else
          raise 'pikafish_uci: upstream Engine::go no longer matches the reviewed embedded patch'
        end

      File.write(output_path, result) unless File.exist?(output_path) && File.read(output_path) == result
    end
  end
end
