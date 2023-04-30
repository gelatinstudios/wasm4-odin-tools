
package midi

import "core:fmt"
import "core:log"
import "core:io"
import "core:os"
import "core:compress"
import "core:math"

MIDI :: struct {
    header: Header,
    tracks: []Track,
}

Chunk_Type :: enum u32be {
    Header = 'M' << 24 | 'T' << 16 | 'h' << 8 | 'd',
    Track  = 'M' << 24 | 'T' << 16 | 'r' << 8 | 'k',
}

Chunk :: struct {
    type: Chunk_Type,
    data: []byte,
}

Header :: struct #packed {
    format:      u16be,
    track_count: u16be,
    division:    u16be,
}

Sysex_Event :: distinct []byte

// TODO: double-check that the 2 u16s below are le...
Sequence_Number        :: distinct u16le
Text                   :: distinct string
Copyright              :: distinct string
Sequence_Or_Track_Name :: distinct string
Instrument_Name        :: distinct string
Lyric                  :: distinct string
Marker                 :: distinct string
Cue_Point              :: distinct string
Program_Name           :: distinct string
Device_Name            :: distinct string
MIDI_Channel_Prefix    :: distinct u16le
MIDI_Port              :: distinct u8
End_Of_Track           :: struct{}
Tempo                  :: distinct int // 24-bits; special treatment parsing
Time_Signature :: struct {
    numerator, denominator: u8,
    midi_clocks_between_clicks: u8,
    thirty_second_notes_in_quarter_note: u8,
}
Key_Signature :: struct {
    flats_or_sharps: i8,
    is_minor_key:    b8,
}
Unknown_Meta_Event    :: distinct []byte

Meta_Event :: union { 
    Sequence_Number,
    Text,
    Copyright,
    Sequence_Or_Track_Name,
    Instrument_Name,
    Lyric,
    Marker,
    Cue_Point,
    Program_Name,
    Device_Name,
    MIDI_Channel_Prefix,
    MIDI_Port,
    End_Of_Track,
    Tempo,
    Time_Signature,
    Key_Signature,
    Unknown_Meta_Event,
}


byte_slice_to_type :: proc(data: []byte, $T: typeid) -> (result: T, error: io.Error) {
    if len(data) != size_of(T) {
	return ---, .Unknown
    }
    if size_of(T) == 0 {
	return {}, .None
    }
    return (cast(^T)&data[0])^, .None
}


read_meta_event :: proc(ctx: ^$C) -> (result: Meta_Event, error: io.Error) {
    using compress
    
    type   := read_data(ctx, byte)             or_return
    length := read_variable_length_number(ctx) or_return
    data   := read_slice(ctx, int(length))     or_return
    
    switch type {	
    case 0: result = byte_slice_to_type(data, Sequence_Number) or_return
    case 1: result = Text(data)
    case 2: result = Copyright(data)
    case 3: result = Sequence_Or_Track_Name(data)
    case 4: result = Instrument_Name(data)
    case 5: result = Lyric(data)
    case 6: result = Marker(data)
    case 7: result = Cue_Point(data)
    case 8: result = Program_Name(data)
    case 9: result = Device_Name(data)

    case 0x20: result = byte_slice_to_type(data, MIDI_Channel_Prefix) or_return
    case 0x21: result = byte_slice_to_type(data, MIDI_Port)           or_return
    case 0x2f: result = byte_slice_to_type(data, End_Of_Track)        or_return
	
    case 0x51:
	if len(data) != 3 {
	    return ---, .Unknown
	}

	time_per_beat := u32(data[0]) << 16 | u32(data[1]) << 8 | u32(data[2])

	result = Tempo(math.round(60000000 / f64(time_per_beat)))
	
    case 0x58:
	// TODO: denominator should probably not be a u8, since it can end up quite large if a large number is given
	//       in practice though, its pretty unlikey to see a time signature > 16 
	ts := byte_slice_to_type(data, Time_Signature) or_return
	ts.denominator = 1 << ts.denominator
	result = ts
	
    case 0x59: result = byte_slice_to_type(data, Key_Signature)  or_return

    case:  result = Unknown_Meta_Event(data)
    }
    
    return result, .None
}

Note_Off :: struct #packed { note, velocity: u8 }
Note_On  :: struct #packed { note, velocity: u8 }

Polyphonic_Pressure  :: struct #packed { note, pressure: u8 }
Controller           :: struct #packed { contoller, value: u8 }
Program_Change       :: distinct u8
Channel_Pressure     :: distinct u8
Pitch_Bend           :: distinct u16 // 14 bits; special-treatment parsing

MIDI_Message :: union {
    Note_Off,
    Note_On,
    Polyphonic_Pressure,
    Controller,
    Program_Change,
    Channel_Pressure,
    Pitch_Bend,
}

MIDI_Event :: struct {
    channel: u8,
    message: MIDI_Message,
}

read_midi_event :: proc(ctx: ^$C, status: u8) -> (result: MIDI_Event, error: io.Error) {
    using compress
    
    result.channel = status & 0x0f

    switch status & 0xf0 {
    case 0x80: result.message = read_data(ctx, Note_Off)            or_return
    case 0x90: result.message = read_data(ctx, Note_On)             or_return
    case 0xa0: result.message = read_data(ctx, Polyphonic_Pressure) or_return
    case 0xb0: result.message = read_data(ctx, Controller)          or_return
    case 0xc0: result.message = read_data(ctx, Program_Change)      or_return
    case 0xd0: result.message = read_data(ctx, Channel_Pressure)    or_return
    case 0xe0:
	data := read_slice(ctx, 2) or_return

	// TODO: double check that this is correct...
	result.message = Pitch_Bend(u16(data[1]) << 7 | u16(data[0]))
	
    case: assert(false) // this should never happen
    }

    return result, .None
}

SysEx_Event :: distinct []byte

read_sysex_event :: proc(ctx: ^$C) -> (result: SysEx_Event, error: io.Error) {
    using compress
    
    length := read_variable_length_number(ctx) or_return
    data := read_slice(ctx, int(length))       or_return 
    
    return SysEx_Event(data), .None
}

Event :: struct {
    delta_time: u32,
    event: union { MIDI_Event, Meta_Event, SysEx_Event },
}

Track :: []Event

read_chunk :: proc(ctx: ^$C) -> (result: Chunk, error: io.Error) {
    using compress

    result.type  = read_data(ctx, Chunk_Type)   or_return
    length      := read_data(ctx, u32be)        or_return
    result.data  = read_slice(ctx, int(length)) or_return

    return
}

read_variable_length_number :: proc(ctx: ^$C) -> (result: u32, error: io.Error) {
    using compress
    // this is translated from the file spec - i feel like this can be written cleaner
    result = u32(read_data(ctx, byte) or_return)
    if result & 0x80 != 0 {
	result &= 0x7f
	for {
	    c := (read_data(ctx, byte) or_return)
	    result = (result << 7) + u32(c & 0x7f)
	    if c & 0x80 == 0 do break
	}
    }
    
    return
}

read_string :: proc(ctx: ^$C) -> (result: string, error: io.Error) {
    using compress

    length := read_variable_length_number(ctx) or_return
    bytes  := read_slice(ctx, int(length))     or_return

    return string(bytes), .None
}

parse :: proc(data: []byte) -> (result: MIDI, error: io.Error) {
    using compress

    ctx := &Context_Memory_Input { input_data = data }

    running_status: byte
    track_index: int

    for len(ctx.input_data) > 0 {
        chunk := read_chunk(ctx) or_return

        switch chunk.type {
        case .Header:
	    result.header = byte_slice_to_type(chunk.data, Header) or_return
	    result.tracks = make([]Track, result.header.track_count)
	    
        case .Track:
            ctx := &Context_Memory_Input { input_data = chunk.data }

	    events: [dynamic]Event
	    
            for len(ctx.input_data) > 0 {
		event: Event
		
                event.delta_time = read_variable_length_number(ctx) or_return

                status := peek_data(ctx, byte) or_return
                defer running_status = status
                
                if status >> 7 == 0 {
                    status = running_status
                } else {
                    read_data(ctx, byte)
                }

		
                switch status {
                case 0x80 ..= 0xef:
		    event.event = read_midi_event(ctx, status) or_return
		    
                case 0xf0: fallthrough
                case 0xf7:
		    event.event = read_sysex_event(ctx) or_return
		    
                // these should not occur in a file
                case 0xf1 ..= 0xf6: fallthrough // system common message
                case 0xf8 ..= 0xfe: // system real time message
                    log.errorf("invalid status byte {}\n", status)
                    return result, .Unknown 
                    
                case 0xff:
		    event.event = read_meta_event(ctx) or_return
		    
                case:
                    assert(false) // this should never happen
                }

		append(&events, event)
            }

	    if track_index < int(result.header.track_count) {
		result.tracks[track_index] = events[:]
		track_index += 1
	    } else {
		delete(events)
	    }
        }
    }

    return result, .None
}

parse_file :: proc(path: string) -> (result: MIDI, ok: bool) {
    data := os.read_entire_file(path) or_return
    error: io.Error
    result, error = parse(data)
    return result, error == .None
}
