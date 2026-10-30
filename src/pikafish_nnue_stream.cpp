#include "pikafish_nnue_stream.h"
#include "pikafish_asset_stream.h"

#define MINIZ_HEADER_FILE_ONLY
#include "external/miniz.h"

#include <algorithm>
#include <array>
#include <climits>
#include <fstream>
#include <streambuf>

class PikafishNnueStream::Buffer final : public std::streambuf {
 public:
  explicit Buffer(const char* path) {
    if (!path) return;
    if (pikafish_asset_is_asset_path(path)) {
      asset_ = pikafish_asset_open(path) != 0;
      if (!asset_) return;
      size_ = pikafish_asset_size();
    } else {
      file_.open(path, std::ios::binary | std::ios::ate);
      if (!file_) return;
      size_ = static_cast<int64_t>(file_.tellg());
    }
    if (size_ <= 0 || static_cast<uint64_t>(size_) > MaxNetworkBytes) return;
    zip_.m_pRead = read_at;
    zip_.m_pIO_opaque = this;
    if (!mz_zip_reader_init(&zip_, static_cast<mz_uint64>(size_), 0)) return;
    zip_open_ = true;
    mz_zip_archive_file_stat entry{};
    if (mz_zip_reader_get_num_files(&zip_) != 1 ||
        !mz_zip_reader_file_stat(&zip_, 0, &entry) || entry.m_is_directory ||
        !entry.m_is_supported || entry.m_is_encrypted ||
        entry.m_uncomp_size == 0 || entry.m_uncomp_size > MaxNetworkBytes) return;
    expected_ = entry.m_uncomp_size;
    iterator_ = mz_zip_reader_extract_iter_new(&zip_, 0, 0);
  }

  ~Buffer() override {
    if (iterator_) mz_zip_reader_extract_iter_free(iterator_);
    if (zip_open_) mz_zip_reader_end(&zip_);
    if (asset_) pikafish_asset_close();
  }

  bool opened() const { return iterator_ != nullptr; }
  bool verified() const {
    const auto unread = gptr() ? static_cast<uint64_t>(egptr() - gptr()) : 0;
    return completed_ && produced_ - unread == expected_;
  }

 protected:
  int_type underflow() override {
    if (gptr() && gptr() < egptr()) return traits_type::to_int_type(*gptr());
    if (!iterator_) return traits_type::eof();
    const size_t count = mz_zip_reader_extract_iter_read(iterator_, bytes_.data(), bytes_.size());
    if (count == 0) {
      // free() checks the final decompressed size and CRC, including stored ZIPs.
      completed_ = mz_zip_reader_extract_iter_free(iterator_) != 0 && produced_ == expected_;
      iterator_ = nullptr;
      return traits_type::eof();
    }
    produced_ += count;
    if (produced_ > expected_) return traits_type::eof();
    setg(bytes_.data(), bytes_.data(), bytes_.data() + count);
    return traits_type::to_int_type(*gptr());
  }

 private:
  static constexpr uint64_t MaxNetworkBytes = 256ULL * 1024 * 1024;
  static size_t read_at(void* context, mz_uint64 offset, void* data, size_t count) {
    auto& self = *static_cast<Buffer*>(context);
    if (offset > static_cast<uint64_t>(self.size_) ||
        count > static_cast<uint64_t>(self.size_) - offset) return 0;
    if (self.asset_) {
      if (pikafish_asset_seek(static_cast<int64_t>(offset)) != static_cast<int64_t>(offset)) return 0;
      size_t read = 0;
      while (read < count) {
        const int block = static_cast<int>(std::min(count - read, static_cast<size_t>(INT_MAX)));
        const int n = pikafish_asset_read(static_cast<char*>(data) + read, block);
        if (n <= 0) break;
        read += static_cast<size_t>(n);
      }
      return read;
    }
    self.file_.clear();
    self.file_.seekg(static_cast<std::streamoff>(offset), std::ios::beg);
    if (!self.file_) return 0;
    self.file_.read(static_cast<char*>(data), static_cast<std::streamsize>(count));
    return static_cast<size_t>(self.file_.gcount());
  }

  mz_zip_archive zip_{};
  mz_zip_reader_extract_iter_state* iterator_ = nullptr;
  std::ifstream file_;
  std::array<char, 65536> bytes_{};
  int64_t size_ = 0;
  uint64_t expected_ = 0, produced_ = 0;
  bool asset_ = false, zip_open_ = false, completed_ = false;
};

PikafishNnueStream::PikafishNnueStream(std::unique_ptr<Buffer> buffer)
    : std::istream(nullptr), buffer_(std::move(buffer)) {
  rdbuf(buffer_.get());
}
PikafishNnueStream::~PikafishNnueStream() = default;
bool PikafishNnueStream::verified() const { return buffer_->verified(); }
std::unique_ptr<PikafishNnueStream> PikafishNnueStream::open(const char* path) {
  auto buffer = std::make_unique<Buffer>(path);
  if (!buffer->opened()) return nullptr;
  return std::unique_ptr<PikafishNnueStream>(new PikafishNnueStream(std::move(buffer)));
}
