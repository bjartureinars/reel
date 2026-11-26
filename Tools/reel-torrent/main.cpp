// reel-torrent: downloads one file of a torrent in 1 GB parts, keeping only a few parts on this Mac at a time,
// so Reel Server can send each part to Google Drive and a 100 GB film never needs 100 GB here.
//
// It is libtorrent with storage of its own: a piece lives in workdir/pieces until every part it touches is
// assembled in workdir/parts; then it is deleted. Reading a deleted piece fails, and libtorrent answers the
// peer that asked with "don't have" (peer_connection::on_disk_read_complete), so nobody ever gets wrong data.
// Every piece is checked against the torrent's own hash before it is used.
//
// Talks to Reel Server one line at a time. Strings are percent-encoded.
//   in:  add <magnet-or-.torrent>          (ignored when workdir/resume.dat exists: the torrent resumes)
//        start <file> <partSize> <window> <uploaded parts, comma separated, or ->   (adds the file to the queue;
//                                            files download in queue order within one budget of `window` parts)
//        uploaded <file> <part>              the part is safely in Drive and may be deleted here
//        limit <down bytes/s> <up bytes/s>   0 = unlimited
//        quit
//   out: meta <infohash> <total size> <name>
//        file <index> <size> <path>   …   files-end
//        status <done bytes of the queued files> <down B/s> <up B/s> <peers> <seeds> <state>
//        part <file> <index> <offset in file> <size> <path>
//        complete <file>
//        error <message>

#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/alert_types.hpp>
#include <libtorrent/disk_interface.hpp>
#include <libtorrent/hasher.hpp>
#include <libtorrent/load_torrent.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/read_resume_data.hpp>
#include <libtorrent/session.hpp>
#include <libtorrent/session_params.hpp>
#include <libtorrent/storage_defs.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/torrent_status.hpp>
#include <libtorrent/write_resume_data.hpp>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <cstdio>
#include <fcntl.h>
#include <fstream>
#include <iostream>
#include <map>
#include <mutex>
#include <set>
#include <sstream>
#include <string>
#include <sys/stat.h>
#include <thread>
#include <unistd.h>
#include <vector>

namespace lt = libtorrent;

namespace {

std::mutex out_lock;

std::string encode(std::string const& s) {
    static char const* hex = "0123456789ABCDEF";
    std::string o;
    for (unsigned char c : s) {
        if (c > 32 && c < 127 && c != '%') o += char(c);
        else { o += '%'; o += hex[c >> 4]; o += hex[c & 15]; }
    }
    return o;
}

std::string decode(std::string const& s) {
    std::string o;
    for (size_t i = 0; i < s.size(); ++i) {
        if (s[i] == '%' && i + 2 < s.size()) { o += char(std::stoi(s.substr(i + 1, 2), nullptr, 16)); i += 2; }
        else o += s[i];
    }
    return o;
}

std::string hex(lt::sha1_hash const& h) {
    static char const* digits = "0123456789abcdef";
    std::string o;
    for (unsigned char c : h) { o += digits[c >> 4]; o += digits[c & 15]; }
    return o;
}

void say(std::string const& line) {
    std::lock_guard<std::mutex> l(out_lock);
    std::cout << line << "\n" << std::flush;
}

lt::storage_error fail(int code = EIO) {
    lt::storage_error e;
    e.ec = lt::error_code(code, lt::generic_category());
    e.operation = lt::operation_t::file_read;
    return e;
}

bool exists(std::string const& path) { struct stat st; return ::stat(path.c_str(), &st) == 0; }

// MARK: - Where everything is, shared by libtorrent's thread and the main loop

// A file Reel Server wants, cut into parts. Several can be on the way at once (a season pack's episodes).
struct FileState {
    int file = -1;
    std::int64_t start = 0, size = 0;
    std::set<int> assembled;   // parts written to workdir/parts
    std::set<int> uploaded;    // parts Reel Server has in Drive (and deleted here)
};

struct Layout {
    std::string work;
    lt::file_storage const* files = nullptr;
    std::int64_t partSize = 1 << 30;
    std::vector<FileState> queue;   // in the order Reel Server asked for them
    std::set<int> pieces;           // pieces complete in workdir/pieces

    std::string piecePath(int p, bool partial) const {
        return work + "/pieces/" + std::to_string(p) + (partial ? ".part" : "");
    }
    std::string partPath(int file, int k) const { return work + "/parts/" + std::to_string(file) + "-" + std::to_string(k); }
    int partCount(FileState const& f) const { return int((f.size + partSize - 1) / partSize); }
    std::int64_t partBegin(FileState const& f, int k) const { return f.start + std::int64_t(k) * partSize; }
    std::int64_t partEnd(FileState const& f, int k) const { return std::min(partBegin(f, k) + partSize, f.start + f.size); }
    std::int64_t pieceBegin(int p) const { return std::int64_t(p) * files->piece_length(); }
    std::int64_t pieceEnd(int p) const { return pieceBegin(p) + files->piece_size(lt::piece_index_t(p)); }
    int firstPiece(FileState const& f, int k) const { return int(partBegin(f, k) / files->piece_length()); }
    int lastPiece(FileState const& f, int k) const { return int((partEnd(f, k) - 1) / files->piece_length()); }
    bool settled(FileState const& f, int k) const { return f.assembled.count(k) || f.uploaded.count(k); }

    FileState* find(int file) {
        for (auto& f : queue) if (f.file == file) return &f;
        return nullptr;
    }

    // The parts of wanted files that a piece overlaps.
    std::vector<std::pair<FileState const*, int>> partsOf(int p) const {
        std::vector<std::pair<FileState const*, int>> out;
        for (auto const& f : queue) {
            std::int64_t b = std::max(pieceBegin(p), f.start), e = std::min(pieceEnd(p), f.start + f.size);
            if (b >= e) continue;
            for (int k = int((b - f.start) / partSize); k <= int((e - 1 - f.start) / partSize); ++k) out.push_back({&f, k});
        }
        return out;
    }

    // A piece can go once every wanted part it touches is assembled or in Drive.
    bool stillNeeded(int p) const {
        for (auto const& [f, k] : partsOf(p)) if (!settled(*f, k)) return true;
        return false;
    }
};

Layout layout;
std::mutex layout_lock;

// MARK: - Storage

int open_piece(int p, bool create) {
    std::string path = layout.piecePath(p, true);
    return ::open(path.c_str(), create ? (O_RDWR | O_CREAT) : O_RDWR, 0644);
}

// Reads `length` bytes at torrent offset `at` from wherever they are now: a finished piece, a piece being
// downloaded, or an assembled part.
bool read_bytes(int piece, int start, int length, char* out) {
    std::lock_guard<std::mutex> l(layout_lock);
    for (bool partial : {false, true}) {
        int fd = ::open(layout.piecePath(piece, partial).c_str(), O_RDONLY);
        if (fd < 0) continue;
        ssize_t got = ::pread(fd, out, size_t(length), start);
        ::close(fd);
        return got == length;
    }
    std::int64_t at = layout.pieceBegin(piece) + start;
    for (auto const& [f, k] : layout.partsOf(piece)) {
        if (!f->assembled.count(k) || f->uploaded.count(k)) continue;
        if (at < layout.partBegin(*f, k) || at + length > layout.partEnd(*f, k)) continue;
        int fd = ::open(layout.partPath(f->file, k).c_str(), O_RDONLY);
        if (fd < 0) return false;
        ssize_t got = ::pread(fd, out, size_t(length), at - layout.partBegin(*f, k));
        ::close(fd);
        return got == length;
    }
    return false;
}

struct ReelDisk final : lt::disk_interface, lt::buffer_allocator_interface {
    explicit ReelDisk(lt::io_context& ioc) : ioc(ioc) {}

    lt::io_context& ioc;
    std::unique_ptr<lt::file_storage> held;

    void settings_updated() override {}

    lt::storage_holder new_torrent(lt::storage_params const& params, std::shared_ptr<void> const&) override {
        std::lock_guard<std::mutex> l(layout_lock);
        layout.files = &params.files;
        return lt::storage_holder(lt::storage_index_t(0), *this);
    }

    void remove_torrent(lt::storage_index_t) override {}
    void abort(bool) override {}

    void async_read(lt::storage_index_t, lt::peer_request const& r,
                    std::function<void(lt::disk_buffer_holder, lt::storage_error const&)> handler,
                    lt::disk_job_flags_t) override {
        char* buffer = new char[size_t(r.length)];
        bool ok = read_bytes(int(static_cast<int>(r.piece)), r.start, r.length, buffer);
        if (!ok) { delete[] buffer; buffer = nullptr; }
        lt::storage_error error = ok ? lt::storage_error() : fail(ENOENT);
        post(ioc, [this, handler, buffer, error] { handler(lt::disk_buffer_holder(*this, buffer), error); });
    }

    bool async_write(lt::storage_index_t, lt::peer_request const& r, char const* buf,
                     std::shared_ptr<lt::disk_observer>, std::function<void(lt::storage_error const&)> handler,
                     lt::disk_job_flags_t) override {
        lt::storage_error error;
        int fd = open_piece(int(static_cast<int>(r.piece)), true);
        if (fd < 0 || ::pwrite(fd, buf, size_t(r.length), r.start) != r.length) {
            error = fail(errno ? errno : EIO);
            error.operation = lt::operation_t::file_write;
        }
        if (fd >= 0) ::close(fd);
        post(ioc, [handler, error] { handler(error); });
        return false;
    }

    std::vector<char> whole(int p, lt::storage_error& error) {
        int size = layout.files->piece_size(lt::piece_index_t(p));
        std::vector<char> data(static_cast<size_t>(size));
        if (!read_bytes(p, 0, size, data.data())) error = fail(ENOENT);
        return data;
    }

    void async_hash(lt::storage_index_t, lt::piece_index_t piece, lt::span<lt::sha256_hash> v2,
                    lt::disk_job_flags_t,
                    std::function<void(lt::piece_index_t, lt::sha1_hash const&, lt::storage_error const&)> handler) override {
        lt::storage_error error;
        int p = int(static_cast<int>(piece));
        std::vector<char> data = whole(p, error);
        lt::sha1_hash hash;
        if (!error) {
            if (!v2.empty()) {
                int size2 = layout.files->piece_size2(piece), blocks = layout.files->blocks_in_piece2(piece);
                std::int64_t offset = 0;
                for (int k = 0; k < blocks; ++k) {
                    std::ptrdiff_t len = std::min<std::int64_t>(lt::default_block_size, size2 - offset);
                    v2[k] = lt::hasher256(data.data() + offset, int(len)).final();
                    offset += len;
                }
            }
            hash = lt::hasher(data).final();
        }
        post(ioc, [handler, piece, hash, error] { handler(piece, hash, error); });
    }

    void async_hash2(lt::storage_index_t, lt::piece_index_t piece, int offset, lt::disk_job_flags_t,
                     std::function<void(lt::piece_index_t, lt::sha256_hash const&, lt::storage_error const&)> handler) override {
        lt::storage_error error;
        int len = std::min(lt::default_block_size, layout.files->piece_size2(piece) - offset);
        std::vector<char> data(static_cast<size_t>(len));
        if (!read_bytes(int(static_cast<int>(piece)), offset, len, data.data())) error = fail(ENOENT);
        lt::sha256_hash hash = error ? lt::sha256_hash() : lt::hasher256(data.data(), len).final();
        post(ioc, [handler, piece, hash, error] { handler(piece, hash, error); });
    }

    void async_move_storage(lt::storage_index_t, std::string p, lt::move_flags_t,
                            std::function<void(lt::status_t, std::string const&, lt::storage_error const&)> handler) override {
        post(ioc, [handler, p] { handler(lt::disk_status::fatal_disk_error, p, fail(ENOTSUP)); });
    }

    void async_release_files(lt::storage_index_t, std::function<void()> handler) override {
        if (handler) post(ioc, handler);
    }

    void async_delete_files(lt::storage_index_t, lt::remove_flags_t,
                            std::function<void(lt::storage_error const&)> handler) override {
        post(ioc, [handler] { handler(lt::storage_error()); });
    }

    // What's here was settled by the main loop from the files in workdir, before the torrent was added.
    void async_check_files(lt::storage_index_t, lt::add_torrent_params const*, lt::aux::vector<std::string, lt::file_index_t>,
                           std::function<void(lt::status_t, lt::storage_error const&)> handler) override {
        post(ioc, [handler] { handler(lt::status_t{}, lt::storage_error()); });
    }

    void async_rename_file(lt::storage_index_t, lt::file_index_t idx, std::string name,
                           std::function<void(std::string const&, lt::file_index_t, lt::storage_error const&)> handler) override {
        post(ioc, [handler, name, idx] { handler(name, idx, lt::storage_error()); });
    }

    void async_stop_torrent(lt::storage_index_t, std::function<void()> handler) override {
        if (handler) post(ioc, handler);
    }

    void async_set_file_priority(lt::storage_index_t, lt::aux::vector<lt::download_priority_t, lt::file_index_t> prio,
                                 std::function<void(lt::storage_error const&, lt::aux::vector<lt::download_priority_t, lt::file_index_t>)> handler) override {
        post(ioc, [handler, prio] { handler(lt::storage_error(), prio); });
    }

    // A piece that failed its hash starts again from nothing.
    void async_clear_piece(lt::storage_index_t, lt::piece_index_t index, std::function<void(lt::piece_index_t)> handler) override {
        {
            std::lock_guard<std::mutex> l(layout_lock);
            ::unlink(layout.piecePath(int(static_cast<int>(index)), true).c_str());
        }
        post(ioc, [handler, index] { handler(index); });
    }

    void free_disk_buffer(char* b) override { delete[] b; }
    void free_multiple_buffers(lt::span<char*> bufs) override { for (char* b : bufs) delete[] b; }
#if TORRENT_DEBUG_BUFFER_POOL
    void rename_buffer(char*, char const*) override {}
#endif
    void update_stats_counters(lt::counters&) const override {}
    std::vector<lt::open_file_state> get_status(lt::storage_index_t) const override { return {}; }
    void submit_jobs() override {}
};

// MARK: - Main loop

struct Client {
    lt::session* session = nullptr;
    lt::torrent_handle handle;
    std::string work;
    int window = 3;
    bool announcedFiles = false;
    std::set<int> announcedComplete;
    std::chrono::steady_clock::time_point lastRefresh{};
    bool started = false;
    std::set<int> rushed;   // pieces given a deadline

    void listFiles() {
        auto ti = handle.torrent_file();
        if (!ti || announcedFiles) return;
        announcedFiles = true;
        auto const& fs = ti->layout();
        say("meta " + hex(ti->info_hashes().get_best()) + " " + std::to_string(fs.total_size()) + " " +
            encode(ti->name()));
        for (auto f : fs.file_range()) {
            if (fs.pad_file_at(f)) continue;
            say("file " + std::to_string(static_cast<int>(f)) + " " + std::to_string(fs.file_size(f)) + " " +
                encode(fs.file_path(f)));
        }
        say("files-end");
        handle.save_resume_data(lt::torrent_handle::save_info_dict);
    }

    // The disk budget is `window` parts: assembled parts waiting for Drive count against it, and the rest goes to
    // the next parts in queue order, across files. Their pieces get priority; everything else waits.
    void prioritize() {
        std::lock_guard<std::mutex> l(layout_lock);
        if (layout.queue.empty() || !layout.files) return;
        int count = layout.files->num_pieces();
        std::vector<lt::download_priority_t> prio(size_t(count), lt::dont_download);
        int budget = window;
        for (auto const& f : layout.queue)
            for (int k : f.assembled) if (!f.uploaded.count(k)) --budget;
        for (auto const& f : layout.queue) {
            for (int k = 0; k < layout.partCount(f) && budget > 0; ++k) {
                if (layout.settled(f, k)) continue;
                --budget;
                for (int p = layout.firstPiece(f, k); p <= layout.lastPiece(f, k); ++p) prio[size_t(p)] = lt::default_priority;
            }
        }
        handle.prioritize_pieces(prio);
    }

    void announcePart(FileState const& f, int k) {
        say("part " + std::to_string(f.file) + " " + std::to_string(k) + " " +
            std::to_string(layout.partBegin(f, k) - f.start) + " " +
            std::to_string(layout.partEnd(f, k) - layout.partBegin(f, k)) + " " + encode(layout.partPath(f.file, k)));
    }

    // Writes every part whose pieces are all here, then deletes the pieces nothing needs any more.
    void assemble() {
        struct Ready { int file, k; };
        std::vector<Ready> ready;
        {
            std::lock_guard<std::mutex> l(layout_lock);
            for (auto const& f : layout.queue)
                for (int k = 0; k < layout.partCount(f); ++k) {
                    if (layout.settled(f, k)) continue;
                    bool all = true;
                    for (int p = layout.firstPiece(f, k); p <= layout.lastPiece(f, k) && all; ++p) all = layout.pieces.count(p) > 0;
                    if (all) ready.push_back({f.file, k});
                }
        }
        for (auto const& r : ready) {
            FileState f;
            {
                std::lock_guard<std::mutex> l(layout_lock);
                FileState* found = layout.find(r.file);
                if (!found) continue;
                f = *found;
            }
            int k = r.k;
            std::string path = layout.partPath(f.file, k), tmp = path + ".tmp";
            int out = ::open(tmp.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
            bool ok = out >= 0;
            std::int64_t written = 0, begin = layout.partBegin(f, k), end = layout.partEnd(f, k);
            std::vector<char> buffer;
            for (int p = layout.firstPiece(f, k); ok && p <= layout.lastPiece(f, k); ++p) {
                std::int64_t b = std::max(begin, layout.pieceBegin(p)), e = std::min(end, layout.pieceEnd(p));
                buffer.resize(size_t(e - b));
                ok = read_bytes(p, int(b - layout.pieceBegin(p)), int(e - b), buffer.data())
                    && ::pwrite(out, buffer.data(), buffer.size(), written) == ssize_t(buffer.size());
                written += e - b;
            }
            if (out >= 0) { ::fsync(out); ::close(out); }
            if (!ok || written != end - begin || ::rename(tmp.c_str(), path.c_str()) != 0) {
                ::unlink(tmp.c_str());
                say("error " + encode("Couldn't write part " + std::to_string(k + 1) + " on this Mac."));
                continue;
            }
            {
                std::lock_guard<std::mutex> l(layout_lock);
                FileState* live = layout.find(f.file);
                if (!live) continue;
                live->assembled.insert(k);
                for (int p = layout.firstPiece(f, k); p <= layout.lastPiece(f, k); ++p)
                    if (!layout.stillNeeded(p)) { ::unlink(layout.piecePath(p, false).c_str()); layout.pieces.erase(p); }
                announcePart(*live, k);
            }
        }
        if (!ready.empty()) prioritize();
        std::lock_guard<std::mutex> l(layout_lock);
        for (auto const& f : layout.queue) {
            if (announcedComplete.count(f.file)) continue;
            bool every = true;
            for (int k = 0; k < layout.partCount(f) && every; ++k) every = layout.settled(f, k);
            if (every) { announcedComplete.insert(f.file); say("complete " + std::to_string(f.file)); }
        }
    }

    // libtorrent's own list of finished pieces is the truth: any it has that we never heard about are taken in.
    void reconcile() {
        if (!handle.is_valid() || layout.queue.empty()) return;
        lt::torrent_status s = handle.status(lt::torrent_handle::query_pieces);
        bool changed = false;
        {
            std::lock_guard<std::mutex> l(layout_lock);
            int count = int(s.pieces.size());
            for (int p = 0; p < count; ++p) {
                if (!s.pieces.get_bit(lt::piece_index_t(p)) || layout.pieces.count(p)) continue;
                if (exists(layout.piecePath(p, true))) {
                    ::rename(layout.piecePath(p, true).c_str(), layout.piecePath(p, false).c_str());
                    layout.pieces.insert(p);
                    changed = true;
                }
            }
        }
        if (changed) assemble();
        rush(s);
    }

    // The last pieces of the first unfinished part hold everything up: give them deadlines, so libtorrent asks
    // several peers for them at once instead of waiting on whichever slow peer it asked first.
    void rush(lt::torrent_status const& s) {
        std::vector<int> late;
        {
            std::lock_guard<std::mutex> l(layout_lock);
            for (auto const& f : layout.queue) {
                int k = 0;
                while (k < layout.partCount(f) && layout.settled(f, k)) ++k;
                if (k >= layout.partCount(f)) continue;
                int first = layout.firstPiece(f, k), last = layout.lastPiece(f, k), missing = 0;
                for (int p = first; p <= last; ++p)
                    if (!layout.pieces.count(p) && !(p < int(s.pieces.size()) && s.pieces.get_bit(lt::piece_index_t(p)))) {
                        ++missing;
                        if (!rushed.count(p)) late.push_back(p);
                    }
                if (missing > std::max(8, (last - first + 1) / 20)) late.clear();
                break;
            }
        }
        int order = 0;
        for (int p : late) {
            handle.set_piece_deadline(lt::piece_index_t(p), 1000 + 100 * order++);
            rushed.insert(p);
        }
    }

    // For diagnosing: pieces wanted now that aren't here, and what libtorrent thinks of them.
    void diagnose() {
        if (!handle.is_valid()) return;
        lt::torrent_status s = handle.status(lt::torrent_handle::query_pieces);
        std::vector<lt::download_priority_t> prio = handle.get_piece_priorities();
        std::vector<lt::partial_piece_info> queue;
        handle.get_download_queue(queue);
        std::lock_guard<std::mutex> l(layout_lock);
        int missing = 0;
        for (int p = 0; p < int(prio.size()); ++p)
            if (prio[size_t(p)] != lt::dont_download && !layout.pieces.count(p)) ++missing;
        say("note " + encode("files queued: " + std::to_string(layout.queue.size()) + ", wanted pieces missing: " +
            std::to_string(missing) + ", downloading: " + std::to_string(queue.size()) + ", peers: " +
            std::to_string(s.num_peers) + ", seeds: " + std::to_string(s.num_seeds) + ", list: " +
            std::to_string(s.list_peers) + ", error: " + s.errc.message()));
    }

    void status() {
        if (!handle.is_valid()) return;
        lt::torrent_status s = handle.status(lt::status_flags_t{});
        std::int64_t done = 0;
        {
            std::lock_guard<std::mutex> l(layout_lock);
            for (auto const& f : layout.queue)
                for (int k = 0; k < layout.partCount(f); ++k)
                    if (layout.settled(f, k)) done += layout.partEnd(f, k) - layout.partBegin(f, k);
            for (int p : layout.pieces)
                for (auto const& [f, k] : layout.partsOf(p))
                    if (!layout.settled(*f, k))
                        done += std::min(layout.pieceEnd(p), layout.partEnd(*f, k)) - std::max(layout.pieceBegin(p), layout.partBegin(*f, k));
        }
        static char const* names[] = {"unused", "checking", "metadata", "downloading", "finished", "seeding", "unused", "resume"};
        int st = int(s.state);
        say("status " + std::to_string(done) + " " + std::to_string(s.download_payload_rate) + " " +
            std::to_string(s.upload_payload_rate) + " " + std::to_string(s.num_peers) + " " + std::to_string(s.num_seeds) +
            " " + (st >= 0 && st < 8 ? names[st] : "unknown"));
    }

    // Adds a file to the queue (or refreshes which of its parts are already in Drive).
    void start(int file, std::int64_t partSize, int windowParts, std::string const& uploaded) {
        auto ti = handle.torrent_file();
        if (!ti) { say("error " + encode("The torrent's details haven't arrived yet.")); return; }
        auto const& fs = ti->layout();
        if (file < 0 || file >= fs.num_files()) { say("error " + encode("No such file in the torrent.")); return; }
        std::vector<int> already;
        {
            std::lock_guard<std::mutex> l(layout_lock);
            layout.partSize = partSize;
            FileState* f = layout.find(file);
            if (!f) {
                FileState added;
                added.file = file;
                added.start = fs.file_offset(lt::file_index_t(file));
                added.size = fs.file_size(lt::file_index_t(file));
                layout.queue.push_back(added);
                f = &layout.queue.back();
            }
            std::stringstream list(uploaded);
            std::string item;
            while (std::getline(list, item, ',')) if (!item.empty() && item != "-") f->uploaded.insert(std::stoi(item));
            for (int k = 0; k < layout.partCount(*f); ++k) {
                if (f->uploaded.count(k)) { ::unlink(layout.partPath(file, k).c_str()); continue; }
                struct stat st;
                if (::stat(layout.partPath(file, k).c_str(), &st) == 0 && st.st_size == layout.partEnd(*f, k) - layout.partBegin(*f, k)) {
                    f->assembled.insert(k);
                    already.push_back(k);
                }
            }
            // Parts already assembled before a restart are offered again; Reel Server ignores ones it has.
            for (int k : already) announcePart(*f, k);
        }
        window = std::max(1, windowParts);
        started = true;
        handle.set_flags(lt::torrent_flags::sequential_download);
        handle.unset_flags(lt::torrent_flags::upload_mode);
        prioritize();
        assemble();
    }

    // The part is in Drive: delete it here, and forget the file once all of it is.
    void uploaded(int file, int k) {
        {
            std::lock_guard<std::mutex> l(layout_lock);
            ::unlink(layout.partPath(file, k).c_str());
            FileState* f = layout.find(file);
            if (!f) return;
            f->uploaded.insert(k);
            if (int(f->uploaded.size()) >= layout.partCount(*f))
                layout.queue.erase(std::remove_if(layout.queue.begin(), layout.queue.end(),
                                                  [file](FileState const& x) { return x.file == file; }), layout.queue.end());
        }
        prioritize();
    }

    // Few peers: ask every tracker and the DHT again, at most every five minutes.
    void refreshPeers() {
        if (!handle.is_valid() || layout.queue.empty()) return;
        auto now = std::chrono::steady_clock::now();
        lt::torrent_status s = handle.status(lt::status_flags_t{});
        if (s.num_peers >= 40 || now - lastRefresh < std::chrono::minutes(5)) return;
        lastRefresh = now;
        handle.force_reannounce(0, -1, lt::torrent_handle::ignore_min_interval);
        handle.force_dht_announce();
    }

    void handle_alerts() {
        std::vector<lt::alert*> alerts;
        session->pop_alerts(&alerts);
        for (lt::alert* a : alerts) {
            if (auto* added = lt::alert_cast<lt::add_torrent_alert>(a)) {
                if (added->error) { say("error " + encode(added->error.message())); continue; }
                handle = added->handle;
                if (handle.torrent_file()) listFiles();
            } else if (lt::alert_cast<lt::metadata_received_alert>(a)) {
                listFiles();
            } else if (auto* done = lt::alert_cast<lt::piece_finished_alert>(a)) {
                int p = static_cast<int>(done->piece_index);
                {
                    std::lock_guard<std::mutex> l(layout_lock);
                    ::rename(layout.piecePath(p, true).c_str(), layout.piecePath(p, false).c_str());
                    layout.pieces.insert(p);
                }
                assemble();
            } else if (auto* saved = lt::alert_cast<lt::save_resume_data_alert>(a)) {
                // Only the torrent's details are kept: which pieces are here is read from workdir on restart.
                std::vector<char> buf = lt::write_resume_data_buf(saved->params);
                std::ofstream f(work + "/resume.dat.tmp", std::ios::binary);
                f.write(buf.data(), std::streamsize(buf.size()));
                f.close();
                ::rename((work + "/resume.dat.tmp").c_str(), (work + "/resume.dat").c_str());
            } else if (std::getenv("REEL_DEBUG") && (a->category() & (lt::alert_category::session_log | lt::alert_category::torrent_log | lt::alert_category::dht_log | lt::alert_category::dht))) {
                say("debug " + a->message());
            } else if (auto* t = lt::alert_cast<lt::tracker_error_alert>(a)) {
                say("note " + encode("tracker " + std::string(t->tracker_url()) + ": " + t->error.message() + " " + t->failure_reason()));
            } else if (auto* bad = lt::alert_cast<lt::torrent_error_alert>(a)) {
                say("error " + encode(bad->error.message()));
            }
        }
    }
};

lt::add_torrent_params resume_or(std::string const& work, std::string const& source, std::string& problem) {
    std::ifstream f(work + "/resume.dat", std::ios::binary);
    if (f) {
        std::vector<char> buf((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
        lt::error_code ec;
        lt::add_torrent_params atp = lt::read_resume_data(buf, ec);
        if (!ec && atp.ti) {
            // Pieces here are whatever workdir/pieces holds whole; everything else is downloaded (or not) again.
            atp.have_pieces.clear();
            atp.have_pieces.resize(atp.ti->num_pieces(), false);
            for (int p = 0; p < atp.ti->num_pieces(); ++p)
                if (exists(work + "/pieces/" + std::to_string(p))) {
                    atp.have_pieces.set_bit(lt::piece_index_t(p));
                    layout.pieces.insert(p);
                }
            atp.unfinished_pieces.clear();
            atp.verified_pieces.clear();
            atp.piece_priorities.clear();
            atp.file_priorities.clear();
            atp.flags &= ~(lt::torrent_flags::paused | lt::torrent_flags::auto_managed | lt::torrent_flags::seed_mode);
            atp.flags |= lt::torrent_flags::default_dont_download;
            return atp;
        }
    }
    lt::error_code ec;
    lt::add_torrent_params atp;
    if (source.rfind("magnet:", 0) == 0) atp = lt::parse_magnet_uri(source, ec);
    else atp = lt::load_torrent_file(source);
    if (ec) problem = ec.message();
    atp.flags &= ~(lt::torrent_flags::paused | lt::torrent_flags::auto_managed);
    // Nothing downloads until Reel Server says which file.
    atp.flags |= lt::torrent_flags::default_dont_download;
    return atp;
}

} // namespace

int main(int argc, char* argv[]) try {
    if (argc != 2) { std::cerr << "usage: reel-torrent <workdir>\n"; return 2; }
    std::string work = argv[1];
    ::mkdir(work.c_str(), 0755);
    ::mkdir((work + "/pieces").c_str(), 0755);
    ::mkdir((work + "/parts").c_str(), 0755);
    layout.work = work;

    lt::settings_pack pack;
    pack.set_int(lt::settings_pack::alert_mask, lt::alert_category::status | lt::alert_category::error |
                 lt::alert_category::storage | lt::alert_category::piece_progress |
                 lt::alert_category::tracker);
    if (std::getenv("REEL_DEBUG"))
        pack.set_int(lt::settings_pack::alert_mask, lt::alert_category::all);
    pack.set_str(lt::settings_pack::user_agent, "Reel/1.0 libtorrent/2.1.3");
    // This network has no IPv6 route; an IPv6 socket only makes trackers look unreachable.
    char const* listen = std::getenv("REEL_LISTEN");
    pack.set_str(lt::settings_pack::listen_interfaces, listen ? listen : "0.0.0.0:0");
    // Fast downloads finish thousands of pieces a minute; a dropped alert must not lose one (and reconcile()
    // catches any that are lost anyway).
    pack.set_int(lt::settings_pack::alert_queue_size, 200000);
    // Ask more than one peer for the same blocks when nothing else is left to ask for.
    pack.set_bool(lt::settings_pack::strict_end_game_mode, false);
    // Ask every tracker in every tier, as uTorrent does. libtorrent's default stops at the first that answers,
    // which left a 13-tracker magnet with one tracker's ~20 peers for an hour at a time.
    pack.set_bool(lt::settings_pack::announce_to_all_trackers, true);
    pack.set_bool(lt::settings_pack::announce_to_all_tiers, true);
    pack.set_int(lt::settings_pack::connections_limit, 400);
    pack.set_bool(lt::settings_pack::enable_dht, true);
    pack.set_str(lt::settings_pack::dht_bootstrap_nodes,
                 "dht.libtorrent.org:25401,router.bittorrent.com:6881,dht.transmissionbt.com:6881,router.utorrent.com:6881");
    pack.set_bool(lt::settings_pack::enable_lsd, true);
    pack.set_bool(lt::settings_pack::enable_upnp, true);
    pack.set_bool(lt::settings_pack::enable_natpmp, true);
    // Drive uploads share this line; a modest share back to the swarm leaves them room.
    pack.set_int(lt::settings_pack::upload_rate_limit, 2 * 1024 * 1024);

    lt::session_params params(pack);
    params.disk_io_constructor = [](lt::io_context& ioc, lt::settings_interface const&, lt::counters&) {
        return std::unique_ptr<lt::disk_interface>(new ReelDisk(ioc));
    };
    lt::session session(std::move(params));
    Client client;
    client.session = &session;
    client.work = work;

    std::mutex commands_lock;
    std::vector<std::string> commands;
    std::vector<std::string> waiting;
    std::atomic<bool> closed{false};
    std::thread reader([&] {
        std::string line;
        while (std::getline(std::cin, line)) {
            std::lock_guard<std::mutex> l(commands_lock);
            commands.push_back(line);
        }
        closed = true;   // Reel Server went away: stop too.
    });
    reader.detach();

    auto lastStatus = std::chrono::steady_clock::now();
    auto lastSave = lastStatus;
    while (true) {
        std::vector<std::string> todo;
        {
            std::lock_guard<std::mutex> l(commands_lock);
            todo.swap(commands);
        }
        // "start" and "uploaded" need the torrent loaded. Right after "add" (or a restart) it usually isn't yet:
        // they wait here instead of being lost, which used to leave a resumed torrent connected but idle.
        bool ready = client.handle.is_valid() && client.handle.torrent_file();
        if (ready && !waiting.empty()) {
            todo.insert(todo.begin(), waiting.begin(), waiting.end());
            waiting.clear();
        }
        for (auto const& line : todo) {
            if (!ready && (line.rfind("start ", 0) == 0 || line.rfind("uploaded ", 0) == 0)) {
                waiting.push_back(line);
                continue;
            }
            std::stringstream in(line);
            std::string verb;
            in >> verb;
            if (verb == "add" && !client.handle.is_valid()) {
                std::string source;
                in >> source;
                std::string problem;
                lt::add_torrent_params atp = resume_or(work, decode(source), problem);
                if (!problem.empty()) { say("error " + encode(problem)); continue; }
                atp.save_path = work;
                session.async_add_torrent(std::move(atp));
            } else if (verb == "start") {
                int file = -1, window = 3;
                std::int64_t part = 1 << 30;
                std::string done = "-";
                in >> file >> part >> window >> done;
                client.start(file, part, window, done);
            } else if (verb == "uploaded") {
                int file = -1, k = -1;
                in >> file >> k;
                if (file >= 0 && k >= 0) client.uploaded(file, k);
            } else if (verb == "limit") {
                int down = 0, up = 0;
                in >> down >> up;
                lt::settings_pack change;
                change.set_int(lt::settings_pack::download_rate_limit, down);
                change.set_int(lt::settings_pack::upload_rate_limit, up);
                session.apply_settings(change);
            } else if (verb == "diagnose") {
                client.diagnose();
            } else if (verb == "quit") {
                closed = true;
            }
        }
        if (closed) break;
        session.wait_for_alert(std::chrono::milliseconds(250));
        client.handle_alerts();
        auto now = std::chrono::steady_clock::now();
        if (now - lastStatus >= std::chrono::seconds(1)) {
            lastStatus = now;
            client.reconcile();
            client.status();
            client.refreshPeers();
        }
        if (client.handle.is_valid() && client.handle.torrent_file() && now - lastSave >= std::chrono::minutes(5)) {
            lastSave = now;
            client.handle.save_resume_data(lt::torrent_handle::save_info_dict);
        }
    }
    if (client.handle.is_valid() && client.handle.torrent_file()) {
        client.handle.save_resume_data(lt::torrent_handle::save_info_dict);
        auto until = std::chrono::steady_clock::now() + std::chrono::seconds(3);
        while (std::chrono::steady_clock::now() < until) {
            session.wait_for_alert(std::chrono::milliseconds(200));
            client.handle_alerts();
        }
    }
    return 0;
} catch (std::exception const& e) {
    say("error " + encode(e.what()));
    return 1;
}
