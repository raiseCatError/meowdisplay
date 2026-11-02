Real streams for the emulator decode check (EmulatorSmokeTest), shaped like the
Mac's: no B-frames, parameter sets repeated on every keyframe, one slice per
picture. Regenerate with:

    ffmpeg -f lavfi -i testsrc=size=320x180:rate=30 -frames:v 45 -pix_fmt yuv420p -c:v libx264 -profile:v baseline -bf 0 -g 30 -x264-params repeat-headers=1:slices=1 -f h264 testsrc-320x180.h264
    ffmpeg -f lavfi -i testsrc=size=320x180:rate=30 -frames:v 45 -pix_fmt yuv420p -c:v libx265 -x265-params bframes=0:keyint=30:repeat-headers=1:slices=1 -f hevc testsrc-320x180.h265
    ffmpeg -f lavfi -i testsrc=size=180x320:rate=30 -frames:v 45 -pix_fmt yuv420p -c:v libx264 -profile:v baseline -bf 0 -g 30 -x264-params repeat-headers=1:slices=1 -f h264 testsrc-180x320.h264
