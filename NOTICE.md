# Third-party notices

RightClip source code is licensed under the MIT License. See [LICENSE](LICENSE).

## FFmpeg

Release builds of RightClip include the `ffmpeg` and `ffprobe` command-line programs and run them as separate processes. RightClip does not link FFmpeg libraries into its own binaries.

Those programs are built from FFmpeg under the GNU Lesser General Public License version 2.1 or later, without `--enable-gpl` and without `--enable-nonfree`. Their license stays LGPL. A build that enables GPL components, including libx264 and libx265, is not a RightClip build.

The pinned build in `eng/ffmpeg.json` enables `--enable-version3`, so its applicable license is LGPLv3. The release includes the LGPLv3 and GPLv3 texts as well as the LGPLv2.1 text.

Each release that contains those programs also contains:

- the text of the LGPLv2.1
- the applicable LGPLv3 and GPLv3 texts for the pinned build
- the FFmpeg source that corresponds to those exact binaries, including the configure line used to build them
- this notice: RightClip uses programs from the FFmpeg project under the LGPLv2.1, and the matching source is included with the release

FFmpeg is a trademark of Fabrice Bellard.

FFmpeg copyright is held by the FFmpeg developers. See the FFmpeg source distribution for the per-file copyright notices.

### Binary redistribution review

The pinned static build also enables external libraries. The downloaded FFmpeg
source archive is the matching **FFmpeg** source, not a complete source bundle
for those external libraries or the upstream build system.

Before publishing binary releases, inventory the enabled dependencies from
`FFmpeg-Build.txt`, include their required copyright/license notices, and supply
the exact corresponding source and build materials required by their licenses.
The absence of `--enable-gpl` does not by itself establish compliance with every
dependency's redistribution terms. Production release automation is gated on
this review; see [release engineering](docs/RELEASING.md).

## .NET runtime

Self-contained packages include the Microsoft .NET runtime and Windows Desktop runtime. Their license and third-party notices are included under `licenses/dotnet-LICENSE.txt` and `licenses/dotnet-ThirdPartyNotices.txt`.
