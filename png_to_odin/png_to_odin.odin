
package png_to_odin

import "core:os"
import "core:fmt"
import "core:strings"
import "core:slice"
import "core:compress"
import "core:path/filepath"

import c "core:c/libc"

import stbi "vendor:stb/image"

Pixel :: distinct [4]u8

main :: proc () {
    usage :: proc () {
	using os
	fmt.println("usage: {} input_path [input_path..]", args[0])
	fmt.println("   generates odin source code for sprite for use with wasm4")
	fmt.println("   supports 1bpp or 2bpp based on number of colors in image")
	fmt.println()
	fmt.println("    image should be monochrome and at least one color should be white")
	exit(0)
    }

    args := os.args
    
    if len(args) < 2 {
	usage()
    }

    fmt.println()
    fmt.println("package assets")
    fmt.println()
    fmt.println(`import "../w4"`)
    fmt.println()

    for path in args[1:] {
	free_all(context.temp_allocator)

	name := strings.to_lower(filepath.short_stem(path), context.temp_allocator)
	
	path_c := strings.clone_to_cstring(path, context.temp_allocator)
	
	w,h,n: c.int
	pixels := cast([^]Pixel)stbi.load(path_c, &w, &h, &n, len(Pixel))
	defer c.free(pixels)
	
	if pixels == nil {
	    fmt.eprintf("ERROR loading file '{}'\n", path)
	    os.exit(1)
	}

	fmt.printf("blit_{} :: proc \"contextless\" (x,y: i32, flags: w4.Blit_Flags = nil) {{\n", name)

	// first pass to get unique colors
	unique_colors: [4]Pixel
	unique_color_count := 1 // the image better have white in it
	{
	    index := 0
	    for y in 0..<h {
		for x in 0..<w {
		    if pixels[index].a == 0 {
			pixels[index].r = 0xff
			pixels[index].g = 0xff
			pixels[index].b = 0xff
			pixels[index].a = 0xff
		    }
		    pixels[index] = ~pixels[index] // white is now 0
		    
		    p := pixels[index]
		    index += 1

		    if !slice.contains(unique_colors[:], p) {
			if unique_color_count >= 4 {
			    fmt.eprintf("ERROR '{}' has too many unique colors!\n", path)
			}
			unique_colors[unique_color_count] = p
			unique_color_count += 1
		    }
		}
	    }
	}
	
	bits_per_pixel := unique_color_count <= 2 ? 1 : 2
	
	index_lut: map[Pixel]int
	index_lut[unique_colors[0]] = 0
	index_lut[unique_colors[1]] = 1
	if bits_per_pixel > 1 {
	    index_lut[unique_colors[2]] = 2
	    index_lut[unique_colors[3]] = 3
	}
	    
	bytes_per_line := int(w) / bits_per_pixel

	fmt.println("    image := [?]byte {")
	
	// write out image
	{
	    bits_into_byte := 0
	    bytes_into_line := 0
	    
	    index := 0
	    for y in 0..<h {
		for x in 0..<w {
		    p := pixels[index]
		    index += 1

		    if bits_into_byte == 0 {
			if bytes_into_line == 0 {
			    fmt.print("        ")
			}

			fmt.print("0b")
		    }

		    if bits_per_pixel == 2 {
			fmt.printf("%02b", index_lut[p])
		    } else {
			fmt.print(index_lut[p])
		    }
			
		    bits_into_byte += bits_per_pixel
		    bits_into_byte %= 8

		    if bits_into_byte == 0 {
			fmt.print(", ")
			
			bytes_into_line += 1
			bytes_into_line %= bytes_per_line
			
			if bytes_into_line == 0 {
			    fmt.println()
			}
		    }
		}
 	    }

	    // remaining bits in last byte
	    if bits_into_byte >0 {
		for _ in 0..<8-bits_into_byte {
		    fmt.print("0")
		}
		fmt.println(",")
	    }
	}

	fmt.println("    }")

	if bits_per_pixel == 2 {
	    fmt.println("    flags := flags")
	    fmt.println("    flags += {.USE_2BPP}")
	}
	
	fmt.printf("    w4.blit(&image[0], x, y, {}, {}, flags)\n", w, h)
	
	fmt.println("}")
	fmt.println()
    }
}
