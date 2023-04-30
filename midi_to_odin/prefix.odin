
package assets

import "../w4"

Audio_Block :: struct {
    start_frequency, end_frequency: u32,
    start_frame, length: u32,
    volume: u32,
}

Audio_Params :: struct {
    duty_cycle: w4.Tone_Duty_Cycle,
    attack, decay, release: u8,
    pan: w4.Tone_Pan,
}

get_song_tick_length :: proc "contextless" (tracks: [][]Audio_Block) -> i64 {
    result: i64
    for track in tracks {
	last_block := track[len(track)-1]
	length := i64(last_block.start_frame + last_block.length)
	result = max(length, result)
    }
    return result
}

play_track :: proc "contextless" (tracks: [][]Audio_Block, indices: []int, params: []Audio_Params, tick: i64, loop := false) {
    tick := tick % get_song_tick_length(tracks)
    
    for track, i in tracks {
        index := &indices[i]

        if index^ < len(track) {
            current_block := track[index^]
                        
            if tick == i64(current_block.start_frame) {
		index^ += 1

		if loop {
		    index^ %= len(track)
		}
		
                param := params[i]

                volume := current_block.volume

                if param.attack != 0 { // set sustain to half volume if asdr is set
                    volume = ((volume/2) << 8) | volume
                }

                sustain := int(current_block.length)
                sustain -= int(param.attack + param.decay + param.release)
                sustain = max(sustain, 0)
                
                duration := w4.Tone_Duration {
                    attack = param.attack,
                    decay = param.decay,
                    release = param.release,
                    sustain = u8(sustain),
                }

                start_freq := u16(current_block.start_frequency)
                end_freq   := u16(current_block.end_frequency)

                channel := w4.Tone_Channel(i)
                
                if channel == .Noise {
                    duration = w4.Tone_Duration {
                        attack = 0,
                        decay = 0,
                        sustain = 4,
                        release = 6,
                    }
                    switch start_freq{
                    case 65: start_freq = 90  // bass drum
                    case 73: start_freq = 460 // snare drum
                    case 92:
                        start_freq = 760
                        duration.sustain = 0 // hi-hat
                    case 139:
                        start_freq = 870
                        duration.sustain = 6
                        duration.release = 18 // cymbal
                    case :
                        start_freq = 460 // default to snare i guess
                    }
                    end_freq = 0
                }
                
                w4.tone_complex(start_freq, end_freq, duration, volume, channel, param.duty_cycle, param.pan)
            }
        }
    }
}
