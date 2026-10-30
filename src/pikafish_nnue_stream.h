#ifndef PIKAFISH_NNUE_STREAM_H
#define PIKAFISH_NNUE_STREAM_H

#include <istream>
#include <memory>

// Sequential NNUE bytes backed by a bounded ZIP reader. The caller must check
// verified() after parsing: EOF alone does not prove the ZIP's CRC is valid.
class PikafishNnueStream final : public std::istream {
 public:
  static std::unique_ptr<PikafishNnueStream> open(const char* path);
  ~PikafishNnueStream() override;
  bool verified() const;

 private:
  class Buffer;
  explicit PikafishNnueStream(std::unique_ptr<Buffer> buffer);
  std::unique_ptr<Buffer> buffer_;
};

#endif
