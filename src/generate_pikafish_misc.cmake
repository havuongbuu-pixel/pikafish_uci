# Lets read_compressed_nnue take its blocks from an Android asset as readily as
# from a file.
#
# Upstream opens an ifstream and streams zstd through it a block at a time,
# which is exactly the right shape - it never holds the network whole. The only
# thing it cannot do is read an entry inside the APK, and that is why the host
# used to copy 49 MB out to storage before startup. This teaches the same loop a
# second source and changes nothing else about it.
#
# Written as a generated copy rather than an edit to the pinned submodule, the
# same way the main() rename and the embedded-failure change are.

if(NOT DEFINED PIKAFISH_MISC_INPUT OR NOT DEFINED PIKAFISH_MISC_OUTPUT)
  message(FATAL_ERROR "pikafish misc generator: missing input/output")
endif()

file(READ "${PIKAFISH_MISC_INPUT}" source)

set(old_text [=[std::stringstream read_compressed_nnue(const std::filesystem::path& fpath) {
    std::stringstream ss;

    std::ifstream fin(fpath, std::ios::binary);
    if (!fin)
        return ss;
    std::vector<char> buffIn(ZSTD_DStreamInSize()), buffOut(ZSTD_DStreamOutSize());
    auto              dctxDeleter = [&](auto* p) {
        if (p)
            ZSTD_freeDCtx(p);
    };
    std::unique_ptr<ZSTD_DCtx, decltype(dctxDeleter)> dctx = {ZSTD_createDCtx(), dctxDeleter};
    if (!dctx)
        return ss;

    while (fin.read(buffIn.data(), buffIn.size()) || fin.gcount() > 0)
    {
        usize         read  = static_cast<usize>(fin.gcount());
        ZSTD_inBuffer input = {buffIn.data(), read, 0};

        while (input.pos < input.size)
        {
            ZSTD_outBuffer output = {buffOut.data(), buffOut.size(), 0};
            usize const    ret    = ZSTD_decompressStream(dctx.get(), &output, &input);
            if (ZSTD_isError(ret))
                return ss;

            ss.write(buffOut.data(), output.pos);
        }
    }

    return ss;
}]=])

set(new_text [=[std::stringstream read_compressed_nnue(const std::filesystem::path& fpath) {
    std::stringstream ss;

    // The path may name an asset inside the Android package instead of a file.
    // From here both are read identically: one block at a time, decompressed as
    // the blocks arrive, so neither the compressed nor the expanded network is
    // ever held whole.
    const std::string path      = fpath.string();
    const bool        fromAsset = pikafish_asset_is_asset_path(path.c_str()) != 0;

    std::ifstream fin;
    if (fromAsset)
    {
        if (!pikafish_asset_open(path.c_str()))
            return ss;
    }
    else
    {
        fin.open(fpath, std::ios::binary);
        if (!fin)
            return ss;
    }

    struct AssetGuard
    {
        bool engaged;
        ~AssetGuard() {
            if (engaged)
                pikafish_asset_close();
        }
    } assetGuard{fromAsset};

    std::vector<char> buffIn(ZSTD_DStreamInSize()), buffOut(ZSTD_DStreamOutSize());
    auto              dctxDeleter = [&](auto* p) {
        if (p)
            ZSTD_freeDCtx(p);
    };
    std::unique_ptr<ZSTD_DCtx, decltype(dctxDeleter)> dctx = {ZSTD_createDCtx(), dctxDeleter};
    if (!dctx)
        return ss;

    const auto nextBlock = [&](usize& read) -> bool {
        if (fromAsset)
        {
            const int n =
              pikafish_asset_read(buffIn.data(), static_cast<int>(buffIn.size()));
            if (n <= 0)
                return false;
            read = static_cast<usize>(n);
            return true;
        }
        // Keeps upstream's condition: the final partial block fails the read
        // but still reports a count, and must not be dropped.
        if (!fin.read(buffIn.data(), buffIn.size()) && fin.gcount() <= 0)
            return false;
        read = static_cast<usize>(fin.gcount());
        return read > 0;
    };

    usize read = 0;
    while (nextBlock(read))
    {
        ZSTD_inBuffer input = {buffIn.data(), read, 0};

        while (input.pos < input.size)
        {
            ZSTD_outBuffer output = {buffOut.data(), buffOut.size(), 0};
            usize const    ret    = ZSTD_decompressStream(dctx.get(), &output, &input);
            if (ZSTD_isError(ret))
                return ss;

            ss.write(buffOut.data(), output.pos);
        }
    }

    return ss;
}]=])

string(FIND "${source}" "${old_text}" old_index)
if(old_index EQUAL -1)
  string(FIND "${source}" "${new_text}" new_index)
  if(new_index EQUAL -1)
    message(FATAL_ERROR
      "pikafish misc generator: upstream read_compressed_nnue no longer matches the reviewed patch")
  endif()
  set(result "${source}")
else()
  string(REPLACE "${old_text}" "${new_text}" result "${source}")
endif()

# The declarations the replacement calls. Placed after the engine's own
# includes so it cannot shadow one of them.
set(include_anchor "#include \"misc.h\"")
string(FIND "${result}" "${include_anchor}" anchor_index)
if(anchor_index EQUAL -1)
  message(FATAL_ERROR "pikafish misc generator: cannot find the misc.h include to anchor to")
endif()
string(FIND "${result}" "#include \"pikafish_asset_stream.h\"" already_index)
if(already_index EQUAL -1)
  string(REPLACE "${include_anchor}"
    "${include_anchor}\n\n#include \"pikafish_asset_stream.h\""
    result "${result}")
endif()

get_filename_component(output_dir "${PIKAFISH_MISC_OUTPUT}" DIRECTORY)
file(MAKE_DIRECTORY "${output_dir}")
file(WRITE "${PIKAFISH_MISC_OUTPUT}" "${result}")
