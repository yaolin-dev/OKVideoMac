#include <ass/ass.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static int failures = 0;
static void log_cb(int level, const char *fmt, va_list ap, void *opaque) {
  char msg[4096];
  vsnprintf(msg, sizeof(msg), fmt, ap);
  if (strstr(msg, "failed to find any fallback") ||
      strstr(msg, "not found in font for") ||
      strstr(msg, "can't find selected font provider"))
    failures++;
  if (level <= 6)
    fprintf(stderr, "[%d] %s\n", level, msg);
}
int main(int argc, char **argv) {
  if (argc != 7)
    return 2;
  ASS_Library *lib = ass_library_init();
  ass_set_message_cb(lib, log_cb, NULL);
  int embedded = !strcmp(argv[2], "embedded");
  if (embedded) {
    FILE *font = fopen(argv[5], "rb");
    if (!font)
      return 4;
    fseek(font, 0, SEEK_END);
    long size = ftell(font);
    rewind(font);
    char *data = malloc(size);
    if (!data || fread(data, 1, size, font) != (size_t)size)
      return 5;
    fclose(font);
    ass_add_font(lib, "fixture.otf", data, size);
    free(data);
  } else
    ass_set_fonts_dir(lib, argv[4]);
  ASS_Renderer *ren = ass_renderer_init(lib);
  ass_set_frame_size(ren, 1280, 360);
  ass_set_storage_size(ren, 1280, 360);
  int isolated = !strcmp(argv[2], "none") || embedded;
  ass_set_fonts(
      ren, !strcmp(argv[2], "none") ? argv[5] : NULL, "Noto Sans CJK SC",
      isolated ? ASS_FONTPROVIDER_NONE : ASS_FONTPROVIDER_AUTODETECT, NULL, 1);
  char script[8192];
  snprintf(
      script, sizeof(script),
      "[Script Info]\nScriptType: v4.00+\nPlayResX: 1280\nPlayResY: 360\n[V4+ "
      "Styles]\nFormat: Name, Fontname, Fontsize, PrimaryColour, "
      "SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, "
      "StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, "
      "Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\nStyle: "
      "Default,%s,40,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,"
      "100,0,0,1,2,0,5,20,20,20,1\n[Events]\nFormat: Layer, Start, End, Style, "
      "Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: "
      "0,0:00:00.00,0:00:10.00,Default,,0,0,0,,"
      "简体中文字幕测试；繁體中文字幕測試\\NEnglish 123 · "
      "标点：，。！？\\N扩展汉字：𠮷 %s 龘\n",
      argv[1], !strcmp(argv[6], "rare") ? "𠀀" : "中");
  ASS_Track *track = ass_read_memory(lib, script, strlen(script), NULL);
  if (!track)
    return 3;
  int change = 0, count = 0;
  ASS_Image *images = ass_render_frame(ren, track, 1000, &change);
  unsigned char *rgb = malloc(1280 * 360 * 3);
  memset(rgb, 24, 1280 * 360 * 3);
  for (ASS_Image *im = images; im; im = im->next) {
    count++;
    unsigned c[3] = {(im->color >> 24) & 255, (im->color >> 16) & 255,
                     (im->color >> 8) & 255};
    unsigned alpha = 255 - (im->color & 255);
    for (int y = 0; y < im->h; y++)
      for (int x = 0; x < im->w; x++) {
        int px = im->dst_x + x, py = im->dst_y + y;
        if (px < 0 || px >= 1280 || py < 0 || py >= 360)
          continue;
        unsigned a = im->bitmap[y * im->stride + x] * alpha;
        for (int k = 0; k < 3; k++) {
          int pos = (py * 1280 + px) * 3 + k;
          rgb[pos] = (c[k] * a + rgb[pos] * (65025 - a)) / 65025;
        }
      }
  }
  FILE *f = fopen(argv[3], "wb");
  fprintf(f, "P6\n1280 360\n255\n");
  fwrite(rgb, 1, 1280 * 360 * 3, f);
  fclose(f);
  printf("{\"font\":\"%s\",\"provider\":\"%s\",\"fallbackFailures\":%d,"
         "\"imageLayers\":%d}\n",
         argv[1], argv[2], failures, count);
  free(rgb);
  ass_free_track(track);
  ass_renderer_done(ren);
  ass_library_done(lib);
  return 0;
}
