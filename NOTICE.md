# Third-party notices

RightClip source code is licensed under the MIT License. See [LICENSE](LICENSE).

## FFmpeg

Release builds of RightClip include the `ffmpeg` and `ffprobe` command-line programs and run them as separate processes. RightClip does not link FFmpeg libraries into its own binaries.

Those programs are built from FFmpeg under the GNU Lesser General Public License version 2.1 or later, without `--enable-gpl` and without `--enable-nonfree`. Their license stays LGPL. A build that enables GPL components, including libx264 and libx265, is not a RightClip build.

The pinned build in `eng/ffmpeg.json` is RightClip's own static build, `9.0.2-rightclip`, from FFmpeg commit `d838f9f9aeb0e09b4d068e2af20a46a12640696f`. It does not enable `--enable-gpl`, `--enable-nonfree`, or `--enable-version3`. The FFmpeg programs are LGPLv2.1 or later. The release includes the LGPLv2.1 text, and the LGPLv3 and GPLv3 texts that accompany the FFmpeg source.

Each release that contains those programs also contains:

- the text of the LGPLv2.1
- the applicable LGPLv3 and GPLv3 texts for the pinned build
- the FFmpeg source that corresponds to those exact binaries, including the configure line used to build them
- the MinGW-w64 winpthreads copyright notice for the statically linked pthread library
- this notice: RightClip uses programs from the FFmpeg project under the LGPLv2.1, and the matching source is included with the release

FFmpeg is a trademark of Fabrice Bellard.

FFmpeg copyright is held by the FFmpeg developers. See the FFmpeg source distribution for the per-file copyright notices.

### Binary redistribution review

The pinned static build links zlib 1.4, openh264 2.7.0, kvazaar 2.3.2, libvpx 1.17.0, and libaom 3.15.3. Their license and patent notices are included under `licenses/`, and each exact source archive is included next to `ffmpeg-source.tar.gz`. The programs were built with gcc 13-win32 from Ubuntu 24.04 `gcc-mingw-w64`. libgcc and libstdc++ are statically linked under the GCC Runtime Library Exception. MinGW-w64 winpthreads is also statically linked through `-lpthread`. Its copyright notice is included as `licenses/winpthreads-LICENSE`.

`FFmpeg-Build.txt` records the configure line, archive hashes, and compiler. Production release automation still requires the protected environment variable `FFMPEG_REDISTRIBUTION_APPROVED=true` after that bundle is reviewed. See [release engineering](docs/RELEASING.md).

## .NET runtime

Self-contained packages include the Microsoft .NET runtime and Windows Desktop runtime. Their license and third-party notices are included under `licenses/dotnet-LICENSE.txt` and `licenses/dotnet-ThirdPartyNotices.txt`.
