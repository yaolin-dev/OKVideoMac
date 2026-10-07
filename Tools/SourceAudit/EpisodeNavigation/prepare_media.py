from pathlib import Path
import wave
root=Path('/private/tmp/OKVideoMac-EpisodeNavigation-Native/Run')
assert not root.exists(), 'Preserve prior evidence by renaming Run before retrying'
root.mkdir(parents=True)
for index in range(1,18):
    with wave.open(str(root/(str(index)+'.wav')),'wb') as stream:
        stream.setnchannels(1); stream.setsampwidth(2); stream.setframerate(8000)
        stream.writeframes(b'\0\0'*8000*(8 if index in (14,15) else 60))
