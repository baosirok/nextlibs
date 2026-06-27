package io.github.anilbeesetti.nextlib.media3ext.ffdecoder;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import androidx.media3.common.util.Log;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.exoplayer.DefaultRenderersFactory;
import androidx.media3.exoplayer.Renderer;
import androidx.media3.exoplayer.audio.AudioRendererEventListener;
import androidx.media3.exoplayer.audio.AudioSink;
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector;
import androidx.media3.exoplayer.text.SubtitleDecoderFactory;
import androidx.media3.exoplayer.text.TextOutput;
import androidx.media3.exoplayer.text.TextRenderer;
import androidx.media3.exoplayer.video.VideoRendererEventListener;
import io.github.anilbeesetti.nextlib.media3ext.renderer.NextTextRenderer;
import java.util.ArrayList;

@UnstableApi
public class NextRenderersFactory extends DefaultRenderersFactory {
    public static final String TAG = "NextRenderersFactory";
    private boolean audioPrefer;
    private boolean videoPrefer;

    public NextRenderersFactory(Context context) {
        super(context);
    }

    public NextRenderersFactory setAudioPrefer(boolean audioPrefer) {
        this.audioPrefer = audioPrefer;
        return this;
    }

    public NextRenderersFactory setVideoPrefer(boolean videoPrefer) {
        this.videoPrefer = videoPrefer;
        return this;
    }

    @Override
    protected void buildAudioRenderers(Context context, int extensionRendererMode, MediaCodecSelector mediaCodecSelector, boolean enableDecoderFallback, AudioSink audioSink, Handler eventHandler, AudioRendererEventListener eventListener, ArrayList<Renderer> out) {
        super.buildAudioRenderers(context, extensionRendererMode, mediaCodecSelector, enableDecoderFallback, audioSink, eventHandler, eventListener, out);
        
        // ⭐ 只有 audioPrefer = true 时才加载 FFmpeg 音频
        if (extensionRendererMode != 0 && this.audioPrefer) {
            int extensionRendererIndex = out.size();
            // 插到前面（优先使用 FFmpeg）
            --extensionRendererIndex;

            try {
                Renderer renderer = new FfmpegAudioRenderer(eventHandler, eventListener, audioSink);
                out.add(extensionRendererIndex, renderer);
                Log.i(TAG, "Loaded FfmpegAudioRenderer.");
            } catch (Exception e) {
                throw new RuntimeException("Error instantiating Ffmpeg extension", e);
            }
        }
    }

    @Override
    protected void buildVideoRenderers(Context context, int extensionRendererMode, MediaCodecSelector mediaCodecSelector, boolean enableDecoderFallback, Handler eventHandler, VideoRendererEventListener eventListener, long allowedVideoJoiningTimeMs, ArrayList<Renderer> out) {
        super.buildVideoRenderers(context, extensionRendererMode, mediaCodecSelector, enableDecoderFallback, eventHandler, eventListener, allowedVideoJoiningTimeMs, out);
        
        // ⭐ 只有 videoPrefer = true 时才加载 FFmpeg 视频
        if (extensionRendererMode != 0 && this.videoPrefer) {
            int extensionRendererIndex = out.size();
            // 插到前面（优先使用 FFmpeg）
            --extensionRendererIndex;

            try {
                Renderer renderer = new FfmpegVideoRenderer(allowedVideoJoiningTimeMs, eventHandler, eventListener, 50);
                out.add(extensionRendererIndex, renderer);
                Log.i(TAG, "Loaded FfmpegVideoRenderer.");
            } catch (Exception e) {
                throw new RuntimeException("Error instantiating Ffmpeg extension", e);
            }
        }
    }

    @Override
    protected void buildTextRenderers(Context context, TextOutput output, Looper outputLooper, int extensionRendererMode, ArrayList<Renderer> out) {
        TextRenderer delegate = new TextRenderer(output, outputLooper, SubtitleDecoderFactory.DEFAULT);
        out.add(new NextTextRenderer(output, outputLooper, SubtitleDecoderFactory.DEFAULT, delegate));
    }
}
