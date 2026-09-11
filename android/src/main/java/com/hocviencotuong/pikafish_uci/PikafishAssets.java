package com.hocviencotuong.pikafish_uci;

import android.content.res.AssetManager;

/**
 * Hands the engine the app's assets so it can read its NNUE network from the
 * package instead of a copy on disk.
 *
 * <p>The network is 49 MB. Pikafish takes it as a filesystem path and streams
 * it in blocks, and an asset inside an APK is a zip entry rather than a file -
 * so the host used to copy the whole thing out to app storage once, leaving the
 * device holding it twice and costing about two seconds on first launch. The
 * native side can read the same blocks straight from the package, but only if
 * somebody gives it an AssetManager, and only a Context has one.
 *
 * <p>Call {@link #register(AssetManager)} from the Activity before the engine
 * starts. Registering twice is harmless; not registering at all leaves the host
 * to fall back to the copy, which still works.
 */
public final class PikafishAssets {

  private PikafishAssets() {}

  private static boolean libraryLoaded = false;

  /**
   * Loads the engine library if needed and hands over the asset manager.
   *
   * @return true when the engine can now read assets.
   */
  public static synchronized boolean install(AssetManager assets) {
    if (!libraryLoaded) {
      try {
        System.loadLibrary("pikafish_uci");
        libraryLoaded = true;
      } catch (UnsatisfiedLinkError error) {
        // Dart FFI loads this library itself when it opens the engine. Losing
        // the race here only costs the asset path, so say so rather than
        // taking the app down for it.
        return false;
      }
    }
    try {
      return register(assets);
    } catch (UnsatisfiedLinkError error) {
      return false;
    }
  }

  private static native boolean register(AssetManager assets);
}
