// =============================================================================
// extract_results.cpp  —  Pull headline numbers out of Vivado synth runs
// =============================================================================
//
// Walks `build/` looking for synth-output subdirectories. From each, parses:
//   - vivado.log               → Fmax, worst slack, achieved period
//   - utilization.rpt          → LUTs, FFs, DSPs, BRAMs (RAMB18, RAMB36)
//   - worst_path.rpt           → critical-path source, dest, logic levels
//   - power.rpt                → total on-chip power (W)
//
// Produces:
//   build/comparison.csv       — CSV (one row per run, easy to import)
//   build/comparison.md        — Markdown table (drops into the report)
// And prints a formatted table to stdout.
//
// USAGE
//   $ g++ -std=c++17 -O2 -o tools/extract_results tools/extract_results.cpp
//   $ ./tools/extract_results
//
//   $ ./tools/extract_results build      # explicit build root
//   $ ./tools/extract_results build acc_  # only directories starting with acc_
//
// REQUIREMENTS
//   C++17 (uses <filesystem>). On Windows: MinGW-w64 or MSVC. On Linux/WSL:
//   any modern g++.
// =============================================================================

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <optional>
#include <regex>
#include <sstream>
#include <string>
#include <vector>

namespace fs = std::filesystem;

// -----------------------------------------------------------------------------
// One row per synth run
// -----------------------------------------------------------------------------
struct RunInfo {
    std::string                 run_tag;
    std::optional<double>       fmax_mhz;
    std::optional<double>       worst_slack_ns;
    std::optional<double>       achieved_period_ns;
    std::optional<int>          luts_total;
    std::optional<int>          luts_logic;
    std::optional<int>          luts_mem;
    std::optional<int>          ffs;
    std::optional<int>          dsps;
    std::optional<int>          bram_tile;
    std::optional<int>          bram18;
    std::optional<int>          bram36;
    std::optional<int>          logic_levels;
    std::optional<double>       total_power_w;
    std::optional<std::string>  crit_source;
    std::optional<std::string>  crit_dest;
};

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------
static std::optional<double> match_double(const std::string& line, const std::regex& re) {
    std::smatch m;
    if (std::regex_search(line, m, re) && m.size() > 1) {
        try { return std::stod(m[1].str()); }
        catch (...) { return std::nullopt; }
    }
    return std::nullopt;
}

static std::optional<int> match_int(const std::string& line, const std::regex& re) {
    std::smatch m;
    if (std::regex_search(line, m, re) && m.size() > 1) {
        try { return std::stoi(m[1].str()); }
        catch (...) { return std::nullopt; }
    }
    return std::nullopt;
}

static std::optional<std::string> match_str(const std::string& line, const std::regex& re) {
    std::smatch m;
    if (std::regex_search(line, m, re) && m.size() > 1) return m[1].str();
    return std::nullopt;
}

// -----------------------------------------------------------------------------
// Parse vivado.log — find the HEADLINE block printed by our TCL script
// -----------------------------------------------------------------------------
static void parse_vivado_log(const fs::path& log_path, RunInfo& info) {
    std::ifstream f(log_path);
    if (!f) return;

    static const std::regex re_slack (R"(Worst slack\s*:\s*([-+]?[0-9.eE+-]+)\s*ns)");
    static const std::regex re_period(R"(Achieved period:\s*([-+]?[0-9.eE+-]+)\s*ns)");
    static const std::regex re_fmax  (R"(^\s*Fmax\s*:\s*([0-9.eE+-]+)\s*MHz)");

    std::string line;
    while (std::getline(f, line)) {
        if (auto v = match_double(line, re_slack))  info.worst_slack_ns      = v;
        if (auto v = match_double(line, re_period)) info.achieved_period_ns  = v;
        if (auto v = match_double(line, re_fmax))   info.fmax_mhz            = v;
    }
}

// -----------------------------------------------------------------------------
// Parse utilization.rpt — pick out the rows we care about
// -----------------------------------------------------------------------------
static void parse_util_rpt(const fs::path& rpt_path, RunInfo& info) {
    std::ifstream f(rpt_path);
    if (!f) return;

    // The report uses ASCII-art tables of the form:
    //   |  Slice LUTs   |  7937 |  0  |  0 |  63400 | 12.52 |
    // We grab the first numeric column after the row label.
    static const std::regex re_lut_total (R"(\|\s*Slice LUTs\s*\|\s*(\d+))");
    static const std::regex re_lut_logic (R"(\|\s*LUT as Logic\s*\|\s*(\d+))");
    static const std::regex re_lut_mem   (R"(\|\s*LUT as Memory\s*\|\s*(\d+))");
    static const std::regex re_ff        (R"(\|\s*Slice Registers\s*\|\s*(\d+))");
    static const std::regex re_dsp       (R"(\|\s*DSPs\s*\|\s*(\d+))");
    static const std::regex re_bram_tile (R"(\|\s*Block RAM Tile\s*\|\s*(\d+))");
    static const std::regex re_b18       (R"(\|\s*RAMB18\s*\|\s*(\d+))");
    static const std::regex re_b36       (R"(\|\s*RAMB36/?FIFO?\*?\s*\|\s*(\d+))");

    std::string line;
    while (std::getline(f, line)) {
        if (!info.luts_total && (info.luts_total = match_int(line, re_lut_total))) {}
        if (!info.luts_logic && (info.luts_logic = match_int(line, re_lut_logic))) {}
        if (!info.luts_mem   && (info.luts_mem   = match_int(line, re_lut_mem)))   {}
        if (!info.ffs        && (info.ffs        = match_int(line, re_ff)))        {}
        if (!info.dsps       && (info.dsps       = match_int(line, re_dsp)))       {}
        if (!info.bram_tile  && (info.bram_tile  = match_int(line, re_bram_tile))) {}
        if (!info.bram18     && (info.bram18     = match_int(line, re_b18)))       {}
        if (!info.bram36     && (info.bram36     = match_int(line, re_b36)))       {}
    }
}

// -----------------------------------------------------------------------------
// Parse worst_path.rpt — first reported path is the worst.
// Also extracts the slack as a fallback when vivado.log didn't have a
// HEADLINE block (older Phase 3/4 runs).
// -----------------------------------------------------------------------------
static void parse_worst_path(const fs::path& rpt_path, RunInfo& info) {
    std::ifstream f(rpt_path);
    if (!f) return;

    static const std::regex re_slack (R"(^\s*Slack\s*\(\w+\)\s*:\s*([-+]?[0-9.]+)\s*ns)");
    static const std::regex re_source(R"(^\s*Source:\s+(\S+))");
    static const std::regex re_dest  (R"(^\s*Destination:\s+(\S+))");
    static const std::regex re_levels(R"(^\s*Logic Levels:\s+(\d+))");

    std::optional<double> slack_from_path;
    std::string line;
    while (std::getline(f, line)) {
        if (!slack_from_path)  slack_from_path     = match_double(line, re_slack);
        if (!info.crit_source  && (info.crit_source  = match_str(line, re_source))) {}
        if (!info.crit_dest    && (info.crit_dest    = match_str(line, re_dest)))   {}
        if (!info.logic_levels && (info.logic_levels = match_int(line, re_levels))) {}

        // Stop after we've collected all four fields for the first path.
        if (slack_from_path && info.crit_source && info.crit_dest && info.logic_levels)
            break;
    }

    // Fall back to worst_path's slack if HEADLINE didn't supply one.
    if (!info.worst_slack_ns && slack_from_path)
        info.worst_slack_ns = slack_from_path;
}

// -----------------------------------------------------------------------------
// Parse power.rpt — total on-chip power
// -----------------------------------------------------------------------------
static void parse_power_rpt(const fs::path& rpt_path, RunInfo& info) {
    std::ifstream f(rpt_path);
    if (!f) return;

    // Vivado emits something like:
    //   | Total On-Chip Power (W)  | 0.123                   |
    static const std::regex re_power(R"(Total On-Chip Power\s*\(W\)\s*\|\s*([0-9.]+))");

    std::string line;
    while (std::getline(f, line)) {
        if (auto v = match_double(line, re_power)) {
            info.total_power_w = v;
            return;
        }
    }
}

// -----------------------------------------------------------------------------
// Process one build subdirectory
// -----------------------------------------------------------------------------
static RunInfo process_dir(const fs::path& dir) {
    RunInfo info;
    info.run_tag = dir.filename().string();

    // Any *.log file (vivado.log or vivado_<name>.log)
    for (const auto& entry : fs::directory_iterator(dir)) {
        const auto& p = entry.path();
        if (p.extension() == ".log") parse_vivado_log(p, info);
    }
    parse_util_rpt   (dir / "utilization.rpt", info);
    parse_worst_path (dir / "worst_path.rpt",  info);
    parse_power_rpt  (dir / "power.rpt",       info);

    return info;
}

// -----------------------------------------------------------------------------
// Output formatting helpers
// -----------------------------------------------------------------------------
static std::string fmt_d(const std::optional<double>& x, int prec = 2) {
    if (!x) return "";
    std::ostringstream os; os << std::fixed << std::setprecision(prec) << *x;
    return os.str();
}
static std::string fmt_i(const std::optional<int>& x) {
    return x ? std::to_string(*x) : std::string("");
}
static std::string fmt_s(const std::optional<std::string>& x, size_t maxlen = 60) {
    if (!x) return "";
    if (x->size() <= maxlen) return *x;
    return x->substr(0, maxlen - 3) + "...";
}

// -----------------------------------------------------------------------------
// Generate CSV
// -----------------------------------------------------------------------------
static std::string make_csv(const std::vector<RunInfo>& runs) {
    std::ostringstream os;
    os << "run_tag,fmax_mhz,worst_slack_ns,achieved_period_ns,"
          "luts_total,luts_logic,luts_mem,ffs,dsps,"
          "bram_tile,bram18,bram36,"
          "logic_levels,total_power_w,crit_source,crit_dest\n";
    for (const auto& r : runs) {
        os << r.run_tag                       << ","
           << fmt_d(r.fmax_mhz, 2)            << ","
           << fmt_d(r.worst_slack_ns, 3)      << ","
           << fmt_d(r.achieved_period_ns, 3)  << ","
           << fmt_i(r.luts_total)             << ","
           << fmt_i(r.luts_logic)             << ","
           << fmt_i(r.luts_mem)               << ","
           << fmt_i(r.ffs)                    << ","
           << fmt_i(r.dsps)                   << ","
           << fmt_i(r.bram_tile)              << ","
           << fmt_i(r.bram18)                 << ","
           << fmt_i(r.bram36)                 << ","
           << fmt_i(r.logic_levels)           << ","
           << fmt_d(r.total_power_w, 3)       << ","
           << "\"" << fmt_s(r.crit_source, 100) << "\","
           << "\"" << fmt_s(r.crit_dest,   100) << "\"\n";
    }
    return os.str();
}

// -----------------------------------------------------------------------------
// Generate Markdown table
// -----------------------------------------------------------------------------
static std::string make_md(const std::vector<RunInfo>& runs) {
    std::ostringstream os;
    os << "# Vivado synth comparison\n\n";
    os << "| Run | Fmax (MHz) | Slack (ns) | Period (ns) | LUTs | FFs | DSPs | BRAMs | Levels | Power (W) |\n";
    os << "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|\n";
    for (const auto& r : runs) {
        os << "| " << r.run_tag
           << " | " << fmt_d(r.fmax_mhz, 1)
           << " | " << fmt_d(r.worst_slack_ns, 3)
           << " | " << fmt_d(r.achieved_period_ns, 3)
           << " | " << fmt_i(r.luts_total)
           << " | " << fmt_i(r.ffs)
           << " | " << fmt_i(r.dsps)
           << " | " << fmt_i(r.bram_tile)
           << " | " << fmt_i(r.logic_levels)
           << " | " << fmt_d(r.total_power_w, 3)
           << " |\n";
    }
    os << "\n## Critical paths\n\n";
    os << "| Run | Source | Destination |\n";
    os << "|---|---|---|\n";
    for (const auto& r : runs) {
        os << "| " << r.run_tag
           << " | `" << fmt_s(r.crit_source, 60) << "`"
           << " | `" << fmt_s(r.crit_dest,   60) << "`"
           << " |\n";
    }
    return os.str();
}

// -----------------------------------------------------------------------------
// Pretty stdout table
// -----------------------------------------------------------------------------
static void print_table(const std::vector<RunInfo>& runs) {
    auto col = [](const std::string& s, int w) {
        std::ostringstream os; os << std::left << std::setw(w) << s; return os.str();
    };
    auto colr = [](const std::string& s, int w) {
        std::ostringstream os; os << std::right << std::setw(w) << s; return os.str();
    };

    std::cout << col("Run", 28)
              << colr("Fmax", 9)
              << colr("Slack", 8)
              << colr("LUTs", 8)
              << colr("FFs", 7)
              << colr("DSPs", 6)
              << colr("BRAM", 6)
              << colr("Lvl", 5)
              << colr("Pwr(W)", 9)
              << "\n";
    std::cout << std::string(86, '-') << "\n";
    for (const auto& r : runs) {
        std::cout << col(r.run_tag, 28)
                  << colr(fmt_d(r.fmax_mhz, 1), 9)
                  << colr(fmt_d(r.worst_slack_ns, 2), 8)
                  << colr(fmt_i(r.luts_total), 8)
                  << colr(fmt_i(r.ffs), 7)
                  << colr(fmt_i(r.dsps), 6)
                  << colr(fmt_i(r.bram_tile), 6)
                  << colr(fmt_i(r.logic_levels), 5)
                  << colr(fmt_d(r.total_power_w, 3), 9)
                  << "\n";
    }
}

// -----------------------------------------------------------------------------
// Main
// -----------------------------------------------------------------------------
int main(int argc, char** argv) {
    fs::path build_root = (argc > 1) ? fs::path(argv[1]) : fs::path("./build");
    std::string filter  = (argc > 2) ? std::string(argv[2]) : std::string("");

    if (!fs::exists(build_root) || !fs::is_directory(build_root)) {
        std::cerr << "ERROR: build_root '" << build_root.string()
                  << "' is not a directory.\n";
        return 1;
    }

    std::vector<RunInfo> runs;
    for (const auto& entry : fs::directory_iterator(build_root)) {
        if (!entry.is_directory()) continue;
        const std::string name = entry.path().filename().string();
        if (!filter.empty() && name.rfind(filter, 0) != 0) continue;  // prefix match
        // Heuristic: skip empty directories
        bool has_data = fs::exists(entry.path() / "utilization.rpt") ||
                        fs::exists(entry.path() / "vivado.log");
        if (!has_data) continue;

        runs.push_back(process_dir(entry.path()));
    }

    // -------------------------------------------------------------------------
    // Derive Fmax / achieved-period from slack when the HEADLINE block in
    // vivado.log was missing (older runs predating our standardized logging).
    // We assume the XDC clock target is 10 ns (= 100 MHz). If your XDC target
    // is different, override TARGET_PERIOD_NS via the env var below.
    // -------------------------------------------------------------------------
    double target_period_ns = 10.0;
    if (const char* env = std::getenv("TARGET_PERIOD_NS")) {
        try { target_period_ns = std::stod(env); }
        catch (...) { /* keep default */ }
    }
    for (auto& r : runs) {
        if (!r.fmax_mhz && r.worst_slack_ns) {
            const double achieved = target_period_ns - *r.worst_slack_ns;
            if (achieved > 0.0) {
                r.achieved_period_ns = achieved;
                r.fmax_mhz           = 1000.0 / achieved;
            }
        }
    }

    std::sort(runs.begin(), runs.end(),
              [](const RunInfo& a, const RunInfo& b){ return a.run_tag < b.run_tag; });

    if (runs.empty()) {
        std::cerr << "WARNING: No matching runs found under " << build_root.string() << ".\n";
        return 0;
    }

    print_table(runs);
    std::cout << "\n";

    // Write CSV + MD
    const auto csv_path = build_root / "comparison.csv";
    const auto md_path  = build_root / "comparison.md";
    {
        std::ofstream f(csv_path); f << make_csv(runs);
    }
    {
        std::ofstream f(md_path);  f << make_md(runs);
    }
    std::cerr << "INFO: " << runs.size() << " run(s) processed.\n"
              << "INFO: CSV   -> " << csv_path.string() << "\n"
              << "INFO: MD    -> " << md_path.string()  << "\n";

    return 0;
}
