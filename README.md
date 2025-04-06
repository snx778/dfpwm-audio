DFPWM-audio
===========

This is a music repository encoded in the [DFPWM](https://wiki.vexatos.com/dfpwm) audio format. This format is used in the [Tape Drive](https://ftb.fandom.com/wiki/Tape_Drive) block in the [Computronics](https://ftb.fandom.com/wiki/Computronics) mod (addon for OpenComputers).

# How to record songs onto the tape?
1. Put the floppy loot disk from Computronics called `Tape` into the computer and install the program by typing `install` in the command prompt.
2. To obtain the file url, navigate to the github repo and copy the url of the `View Raw` link by performing `Right Click > Copy Link`.
3. Use command `tape write <url-to-file>` to write an audiofile onto the tape (OpenComputers shell).
4. Use command `tape label <new-tape-name>` to name the tape (in OpenComputers shell).

# How to convert mp3/wav/etc to DFPWM?
1. Install [ffmpeg](https://www.ffmpeg.org/).
2. Download the [LionRay](https://github.com/BlueAmulet/LionRay) wav to DFPWM audio converter.
3. With the command `ffmpeg -i <input-audio>.mp3 <output-audio>.wav` (in your system's shell) convert your file to the `.wav` format.
4. With the help of LionRay convert your wav file into the DFPWM format **(For 1.7.10, make sure that you unchecked the `DFPWM1a` option)**.
