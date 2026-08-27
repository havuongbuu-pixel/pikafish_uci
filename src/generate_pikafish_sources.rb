# Generates, inside the calling podspec's own directory, everything its
# source_files needs to compile the engine.
#
# CocoaPods silently drops any source_files pattern that escapes the pod's own
# root (the podspec's directory) via `../` — it never raises, the file is just
# not compiled, which is what made the first version of these podspecs produce
# an app that linked "successfully" with none of the engine's code in it. This
# is exactly what the vanilla `flutter create --template=plugin_ffi` template
# works around with a `Classes/` forwarder that `#include`s a single file from
# `../src`; this plugin has 18 translation units (17 engine sources plus the
# bridge) instead of one, so this generates one forwarder per file instead of
# hand-maintaining 18 of them.
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
    benchmark bitboard evaluate material misc movegen movepick position
    psqt endgame search thread timeman tt uci ucioption tune
  ].freeze

  def self.generate!(pod_dir)
    pikafish_src = File.expand_path(File.join(pod_dir, '..', 'third_party', 'Pikafish-HCE', 'src'))
    bridge_src = File.expand_path(File.join(pod_dir, '..', 'src', 'pikafish_bridge.cpp'))
    out_dir = File.join(pod_dir, 'generated')
    FileUtils.mkdir_p(out_dir)

    write_forwarder(File.join(out_dir, 'pikafish_bridge.cpp'), bridge_src)
    ENGINE_SOURCES.each do |name|
      write_forwarder(File.join(out_dir, "#{name}.cpp"), File.join(pikafish_src, "#{name}.cpp"))
    end
    GeneratedMain.generate!(pod_dir, pikafish_src)
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
        raise "pikafish_uci: Pikafish-HCE sources missing at #{input_path}. " \
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

      source = File.read(input_path)
      old_count = source.scan(Regexp.new(Regexp.escape(old_line))).length
      new_count = source.scan(Regexp.new(Regexp.escape(new_line))).length

      result =
        if old_count == 1 && new_count.zero?
          source.sub(old_line, new_line)
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
end
