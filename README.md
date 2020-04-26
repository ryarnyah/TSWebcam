# TSWebcam for IOS

Create your own webcam for GNU/Linux.

Packages needed to be installed:
* `v4l2loopback` (video loop)
* `ffmpeg` (trascode h264/raw & aac/pcm)
* `alsa` (sound aloop)
* `avahi-utils` (mDNS discovery)

To run it on Linux:
* load snd-aloop module `sudo modprobe snd-aloop`
* load v4l2loopback module `sudo modprobe v4l2loopback video_nr=4 exclusive_caps=1`
* publish mDNS service `avahi-publish -s v4l2x _webcam._tcp 8088`
* start ffmpeg to stream to loop devices `ffmpeg -i 'tcp://0.0.0.0:8088?listen=1' -map 0:v -f v4l2 /dev/video4 -map 0:a -f alsa hw:1,0`
(`/dev/vdeo4` and `hw:1,0` may change. Use `arecord -l` and `v4l2-ctl --list-devices` to find them)
