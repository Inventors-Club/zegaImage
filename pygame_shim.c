/*
 * pygame_shim.c — minimal libretro shim core for pygame games.
 *
 * RetroArch loads this as if it were an emulator core; when given a .py
 * file as "content", it writes the path to /tmp/zega-pygame-pending and
 * signals RETRO_ENVIRONMENT_SHUTDOWN. A bash wrapper around RetroArch
 * (zega-retroarch-wrapper) sees the pending file, exits the RetroArch
 * loop, runs `python3 <path>`, then re-launches RetroArch — so to the
 * student pygame games appear inside RetroArch's normal game menu
 * alongside emulator ROMs.
 *
 * No external libretro.h dependency — the few API types we need are
 * defined inline. Build with:
 *   gcc -O2 -fPIC -Wall -shared -o pygame_shim_libretro.so pygame_shim.c
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdarg.h>
#include <time.h>
#include <signal.h>
#include <unistd.h>

/* ----- vendored libretro API subset --------------------------------- */

#define RETRO_API_VERSION           1
#define RETRO_ENVIRONMENT_SHUTDOWN  7
#define RETRO_REGION_NTSC           0

struct retro_system_info {
    const char *library_name;
    const char *library_version;
    const char *valid_extensions;
    bool        need_fullpath;
    bool        block_extract;
};

struct retro_game_geometry {
    unsigned base_width;
    unsigned base_height;
    unsigned max_width;
    unsigned max_height;
    float    aspect_ratio;
};

struct retro_system_timing {
    double fps;
    double sample_rate;
};

struct retro_system_av_info {
    struct retro_game_geometry geometry;
    struct retro_system_timing timing;
};

struct retro_game_info {
    const char *path;
    const void *data;
    size_t      size;
    const char *meta;
};

typedef bool   (*retro_environment_t)(unsigned cmd, void *data);
typedef void   (*retro_video_refresh_t)(const void *data, unsigned width, unsigned height, size_t pitch);
typedef void   (*retro_audio_sample_t)(int16_t left, int16_t right);
typedef size_t (*retro_audio_sample_batch_t)(const int16_t *data, size_t frames);
typedef void   (*retro_input_poll_t)(void);
typedef int16_t (*retro_input_state_t)(unsigned port, unsigned device, unsigned index, unsigned id);

/* ----- shim state --------------------------------------------------- */

#define PENDING_FILE "/tmp/zega-pygame-pending"
#define LOG_FILE     "/tmp/pygame-shim.log"

static void shim_log(const char *fmt, ...)
{
    FILE *f = fopen(LOG_FILE, "a");
    if (!f) return;
    time_t t = time(NULL);
    struct tm tm_;
    localtime_r(&t, &tm_);
    fprintf(f, "%02d:%02d:%02d ", tm_.tm_hour, tm_.tm_min, tm_.tm_sec);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fclose(f);
}

static retro_environment_t        env_cb;
static retro_video_refresh_t      video_cb;
static retro_input_poll_t         input_poll_cb;
static bool                       shutdown_sent;
static unsigned                   run_count;
static uint16_t                   blank_frame[320 * 240];

/* ----- libretro entry points (most are no-op for our use) ----------- */

void retro_set_environment(retro_environment_t cb)         { env_cb = cb; }
void retro_set_video_refresh(retro_video_refresh_t cb)     { video_cb = cb; }
void retro_set_audio_sample(retro_audio_sample_t cb)       { (void)cb; }
void retro_set_audio_sample_batch(retro_audio_sample_batch_t cb) { (void)cb; }
void retro_set_input_poll(retro_input_poll_t cb)           { input_poll_cb = cb; }
void retro_set_input_state(retro_input_state_t cb)         { (void)cb; }

void retro_init(void)
{
    memset(blank_frame, 0, sizeof(blank_frame));
    shutdown_sent = false;
    run_count = 0;
    shim_log("retro_init called");
}
void retro_deinit(void) { shim_log("retro_deinit called"); }

unsigned retro_api_version(void) { return RETRO_API_VERSION; }

void retro_get_system_info(struct retro_system_info *info)
{
    memset(info, 0, sizeof(*info));
    info->library_name     = "pygame-shim";
    info->library_version  = "0.1";
    info->valid_extensions = "py";
    info->need_fullpath    = true;   /* we hand path to python3, not bytes */
    info->block_extract    = true;
}

void retro_get_system_av_info(struct retro_system_av_info *info)
{
    memset(info, 0, sizeof(*info));
    info->timing.fps         = 60.0;
    info->timing.sample_rate = 44100.0;
    info->geometry.base_width  = 320;
    info->geometry.base_height = 240;
    info->geometry.max_width   = 320;
    info->geometry.max_height  = 240;
    info->geometry.aspect_ratio = 320.0f / 240.0f;
}

void retro_set_controller_port_device(unsigned port, unsigned device) { (void)port; (void)device; }
void retro_reset(void) {}

bool retro_load_game(const struct retro_game_info *info)
{
    if (!info || !info->path) {
        shim_log("retro_load_game called with NULL info or path");
        return false;
    }
    shim_log("retro_load_game path=%s", info->path);

    FILE *f = fopen(PENDING_FILE, "w");
    if (!f) {
        shim_log("retro_load_game: fopen %s FAILED", PENDING_FILE);
        return false;
    }
    fprintf(f, "%s\n", info->path);
    fclose(f);
    shim_log("retro_load_game: wrote %s", PENDING_FILE);

    shutdown_sent = false;
    return true;
}

void retro_run(void)
{
    run_count++;
    if (run_count <= 3 || run_count % 60 == 0)
        shim_log("retro_run #%u video_cb=%p env_cb=%p shutdown_sent=%d",
                 run_count, (void*)video_cb, (void*)env_cb, shutdown_sent);

    if (video_cb)      video_cb(blank_frame, 320, 240, 320 * sizeof(uint16_t));
    if (input_poll_cb) input_poll_cb();

    if (!shutdown_sent && env_cb) {
        /* RETRO_ENVIRONMENT_SHUTDOWN actually means "close currently
         * loaded content" in RetroArch — it triggers retro_unload_game +
         * retro_deinit but then returns to the menu. We need the process
         * to exit so the wrapper can `python3 <game>`.
         *
         * SIGTERM doesn't work: RetroArch's signal handler catches it and
         * downgrades to a content-unload, leaving the process alive at
         * the menu. SIGKILL can't be caught and gives us the clean exit
         * we need. The wrapper then sees the non-zero exit, reads the
         * pending file, launches the game.
         *
         * We don't lose state because pygame games don't have RetroArch
         * save data — the pending file IS the only state we care about
         * and it's already on disk. */
        bool rv = env_cb(RETRO_ENVIRONMENT_SHUTDOWN, NULL);
        shim_log("retro_run sent SHUTDOWN, env_cb returned %d", rv);
        shutdown_sent = true;
        if (raise(SIGKILL) != 0)
            shim_log("raise(SIGKILL) FAILED");
        else
            shim_log("raised SIGKILL");
    }
}

void retro_unload_game(void) { shim_log("retro_unload_game called"); }

unsigned retro_get_region(void) { return RETRO_REGION_NTSC; }

bool retro_load_game_special(unsigned game_type, const struct retro_game_info *info, size_t num_info)
{ (void)game_type; (void)info; (void)num_info; return false; }

size_t retro_serialize_size(void)               { return 0; }
bool   retro_serialize(void *d, size_t s)       { (void)d; (void)s; return false; }
bool   retro_unserialize(const void *d, size_t s){ (void)d; (void)s; return false; }

void retro_cheat_reset(void)                                 {}
void retro_cheat_set(unsigned i, bool e, const char *c)      { (void)i; (void)e; (void)c; }

void *retro_get_memory_data(unsigned id) { (void)id; return NULL; }
size_t retro_get_memory_size(unsigned id) { (void)id; return 0; }
