package collections

RingBuffer :: struct($T : typeid) {
    length : u32,
    size : u32,
    begin : u32,
    last : u32,
    data : [dynamic]T
}

ringbuffer_init :: proc(buffer : ^RingBuffer($T), length : u32) {
    reserve_dynamic_array(&buffer.data, length)
    buffer.length = length;
    buffer.size = 0;
    buffer.begin = 0;
    buffer.last = 0;
}

ringbuffer_destroy :: proc(buffer : ^RingBuffer) {
    delete_dynamic_array(buffer.data)
}

ringbuffer_push :: proc(buffer : ^RingBuffer($T), value : $TVal) {
    if last == length - 1 {
        last = 0;
    } else {
        last += 1;
    }

    if buffer.last == buffer.begin { 
        if(buffer.begin == buffer.length - 1) {
            buffer.begin = 0;
        } else {
            buffer.begin = 1;
        }
    }

    if(buffer.size <= buffer.length - 1) {
        buffer.size += 1;
    }

    buffer.data[buffer.last] = value;
}

ringbuffer_pop :: proc(buffer : ^RingBuffer($T)) {
    if buffer.size == 0 {
        return;
    }

    if buffer.last == 0 {
        buffer.last = buffer.length - 1;
    }
}

ringbuffer_get_offset :: proc(buffer : ^RingBuffer($T), index : u32) -> (offset: u32, ok: bool) {
    if index >= buffer.size {
        return 0, false;
    }

    index := (buffer.begin + index) % buffer.length;
    return index, true;
}

ringbuffer_get :: proc(buffer : ^RingBuffer($T), index : u32) ->  (value: T, ok: bool) {
    offset, offsetok := ring_buffer_get_offset(buffer, index);

    if !offsetok {
        return {}, false;
    }

    return buffer.data[index], true;
}

ringbuffer_size :: proc(buffer : ^RingBuffer($T)) {
    return buffer.size;
}
