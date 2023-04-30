
package midi_to_odin

import "core:os"
import "core:fmt"
import "core:math"
import p "core:path/filepath"

import "midi"

process_tracks :: proc(tracks: []midi.Track, division: int, name: string) {
    using midi

    channels := [?]string { "Pulse1", "Pulse2", "Triangle", "Noise" }

    Tempo_Listing :: struct {
        min_time, max_time: i64,
        tempo: midi.Tempo,
    }
    
    tempo_map: [dynamic]Tempo_Listing
    defer delete(tempo_map)

    push_tempo :: proc(tempo_map: ^[dynamic]Tempo_Listing, tempo: midi.Tempo,
                       time: i64, current_min_time: ^i64, current_tempo: ^midi.Tempo)
    {
        if time != 0 {
            new_listing := Tempo_Listing {
                min_time = current_min_time^,
                max_time = time-1,
                tempo = current_tempo^,
            }
            append(tempo_map, new_listing)
            current_min_time^ = time
        }
        current_tempo^ = tempo
    }

    {
        time :i64 = 0
        current_min_time := i64(0)
        current_tempo := Tempo(120)
        
        for event in tracks[0] {
            using event

            time += auto_cast delta_time

            meta_event, meta_ok := event.(Meta_Event)
            if !meta_ok do continue

            tempo, tempo_ok := meta_event.(Tempo)
            if !tempo_ok do continue
            
            push_tempo(&tempo_map, tempo, time, &current_min_time, &current_tempo)
        }
        push_tempo(&tempo_map, 0, time, &current_min_time, &current_tempo)
    }

    if len(tempo_map) == 1 {
        m := &tempo_map[0].max_time
        m^ = max(type_of(m^))
    }

    time_to_frame :: proc (tempo_map: []Tempo_Listing, time: i64, division: int) -> i64 {
        result :i64 = 0
        for listing in tempo_map {
            time_in_listing := time >= listing.min_time && time <= listing.max_time

            length: i64
            if  time_in_listing {
                length = time - listing.min_time + 1
            } else {
                length = listing.max_time - listing.min_time + 1
            }

            length_in_quarter_notes := f64(length) / f64(division)
            seconds := length_in_quarter_notes / f64(listing.tempo) * 60
            frames := i64(math.round(seconds * 60.0))

            result += frames

            if time_in_listing do break
        }
        return result
    }
    
    for track, i in tracks {
        channel := channels[i]

        fmt.printf("{}_{} := [?]Audio_Block {{\n", name, channel)

        pitch_bending := false
        time: i64 = 0
        note_needs_to_be_output := false
        current_note: u8 = 0
        note_start_frame: i64 = 0
        current_velocity: u32 = 0    

        for event, i in track {
            using event

            time += i64(delta_time)

            midi_event, ok := event.(MIDI_Event)
            if !ok do continue

            frame := time_to_frame(tempo_map[:], time, division)

            note_on,   is_note_on  := midi_event.message.(Note_On)
            note_off,  is_note_off := midi_event.message.(Note_Off)
            _, is_pitch_bend := midi_event.message.(Pitch_Bend)

            if is_pitch_bend {
                pitch_bending = note_needs_to_be_output
            }
            
            if is_note_off {
                note_on.velocity = 0
                note_on.note = note_off.note
                is_note_on = true
            }

            if !is_note_on do continue

            to_freq :: proc(note: u8) -> int {
                return int(math.round(midi.equal_temperament[note]))
            }

            do_output := note_needs_to_be_output && (note_on.velocity != 0 || note_on.note == current_note)
            if do_output {
                length := frame - note_start_frame + 1

                start_frequency := to_freq(current_note)
                end_frequency: int = 0

                if pitch_bending {
                    // get next note on
                    for event in track[i+1:] {
                        midi_event, is_midi_event := event.event.(MIDI_Event)
                        if !is_midi_event do continue

                        note_on, is_note_on := midi_event.message.(Note_On)

                        if is_note_on && note_on.velocity > 0 {
                            end_frequency = to_freq(note_on.note)
                            pitch_bending = false
                            break
                        }
                    }
                }

                velocity := u32(f32(current_velocity)/127.0 * 100.0)
                
                fmt.printf("    {{ {: 6d}, {: 6d}, {: 6d}, {: 6d}, {: 6d}}},\n",
                           start_frequency, end_frequency,
                           note_start_frame, length, velocity)

                note_needs_to_be_output = false
            }
            
            if note_on.velocity != 0 {
                current_note = note_on.note
                note_start_frame = frame
                current_velocity = u32(note_on.velocity)

                note_needs_to_be_output = true
            }
        }
        fmt.println("}")
    }

    fmt.printf("play_{} :: proc \"contextless\" (indices: []int, params: []Audio_Params, tick: i64, loop := false) {{\n", name)
    
    fmt.printf("    tracks := [][]Audio_Block {{\n")
    
    for channel in channels {
        fmt.printf("        {}_{}[:],\n", name, channel)
    }
    fmt.println("    }")
    fmt.println("    play_track(tracks, indices, params, tick, loop)")
    fmt.println("}")
}

main :: proc () {
    fmt.println(#load("prefix.odin", string))
    for path in os.args[1:] {
        defer free_all(context.allocator)

        file, ok := midi.parse_file(path)
        assert(ok)
        
        using file

        assert(len(tracks) == 3 || len(tracks) == 4)
        assert(header.division & 0x8000 == 0) // i don't know how to support this division type!

        name := p.stem(path)
        process_tracks(tracks, int(header.division), name)
    }
}
