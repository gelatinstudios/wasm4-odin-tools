
@echo off

odin build png_to_odin.odin -file -o:speed
if exist png_to_odin.exe move png_to_odin.exe ..