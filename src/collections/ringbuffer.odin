package collections

RingBuffer :: struct($ElementType : typeid) {
    length : u32,
    size   : u32,
    begin  : u32,
    last   : u32,
    data   : [dynamic]ElementType,
}

ringbuffer_init :: proc(buffer : ^RingBuffer($ElementType), length : u32) {
    reserve_dynamic_array(&buffer.data, length)
    buffer.length = length
    buffer.size   = 0
    buffer.begin  = 0
    buffer.last   = 0
}

ringbuffer_destroy :: proc(buffer : ^RingBuffer) {
    delete_dynamic_array(buffer.data)
}

ringbuffer_push :: proc(buffer : ^RingBuffer($ElementType), value : ElementType) {
    // Advance write head one slot, wrapping at the end of the backing array.
    if buffer.last == buffer.length - 1 {
        buffer.last = 0
    } else {
        buffer.last += 1
    }

    // When the buffer is full, write head meets read head — push out the oldest
    // entry by advancing `begin` one slot (also wrapping).
    if buffer.last == buffer.begin && buffer.size == buffer.length {
        if buffer.begin == buffer.length - 1 {
            buffer.begin = 0
        } else {
            buffer.begin += 1
        }
    }

    if buffer.size < buffer.length {
        buffer.size += 1
    }

    buffer.data[buffer.last] = value
}

ringbuffer_pop :: proc(buffer : ^RingBuffer($ElementType)) {
    if buffer.size == 0 {
        return
    }

    if buffer.last == 0 {
        buffer.last = buffer.length - 1
    } else {
        buffer.last -= 1
    }

    buffer.size -= 1
}

ringbuffer_get_offset :: proc(buffer : ^RingBuffer($ElementType), index : u32) -> (offset: u32, ok: bool) {
    if index >= buffer.size {
        return 0, false
    }

    wrapped_index := (buffer.begin + index) % buffer.length
    return wrapped_index, true
}

ringbuffer_get :: proc(buffer : ^RingBuffer($ElementType), index : u32) -> (value: ElementType, ok: bool) {
    offset, offset_ok := ringbuffer_get_offset(buffer, index)

    if !offset_ok {
        return {}, false
    }

    return buffer.data[offset], true
}

ringbuffer_size :: proc(buffer : ^RingBuffer($ElementType)) -> u32 {
    return buffer.size
}
