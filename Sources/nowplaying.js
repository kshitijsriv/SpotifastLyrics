// Prints a JSON line whenever macOS "Now Playing" changes. Runs under osascript,
// which is still allowed to read MediaRemote on recent macOS versions.
ObjC.import("Foundation");
$.NSBundle.bundleWithPath("/System/Library/PrivateFrameworks/MediaRemote.framework/").load;
const R = $.NSClassFromString("MRNowPlayingRequest");
const out = $.NSFileHandle.fileHandleWithStandardOutput;
const v = (d, k) => ObjC.unwrap(d.valueForKey("kMRMediaRemoteNowPlayingInfo" + k));
let last = "";
while (true) {
  let msg = { playing: false };
  try {
    const info = R.localNowPlayingItem.nowPlayingInfo;
    const app = ObjC.unwrap(R.localNowPlayingPlayerPath.client.bundleIdentifier);
    if (info && !info.isNil()) {
      const ts = v(info, "Timestamp");
      msg = {
        playing: true, app: app,
        title: v(info, "Title") || "", artist: v(info, "Artist") || "", album: v(info, "Album") || "",
        duration: v(info, "Duration") || 0, elapsed: v(info, "ElapsedTime") || 0,
        rate: v(info, "PlaybackRate") || 0, timestamp: ts ? ts.getTime() / 1000 : 0,
      };
    }
  } catch (e) {}
  const line = JSON.stringify(msg);
  if (line !== last) {
    last = line;
    out.writeData($(line + "\n").dataUsingEncoding($.NSUTF8StringEncoding));
  }
  delay(0.5);
}
