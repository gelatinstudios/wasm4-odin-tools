
@echo off

odin build midi_to_odin.odin -file -debug
if exist midi_to_odin.exe move midi_to_odin.exe ..