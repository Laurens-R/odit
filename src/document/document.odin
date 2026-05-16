package odin

import "core:strings"
import "core:bytes"

import "../collections"

DocumentBufferKind :: enum {
    Source,
    Edit
}

DocumentBuffer :: struct {
    kind : DocumentBufferKind,
    buffer : bytes.Buffer
}

Document :: struct {
    sourceBuffer : DocumentBuffer,
    editBuffer : DocumentBuffer,

}

document_buffer_init :: proc(buffer: ^DocumentBuffer, kind : DocumentBufferKind, initial := "") {
    buffer.kind = kind
    bytes.buffer_init_string(&buffer.buffer, initial)
}

document_buffer_destroy :: proc(buffer: ^DocumentBuffer) {
    bytes.buffer_destroy(&buffer.buffer)
}

document_buffer_append :: proc(buffer: ^DocumentBuffer, str : string) {
    bytes.buffer_write_string(&buffer.buffer, str)
}

document_bufer_getslice :: proc(buffer: ^DocumentBuffer, from : u32, length : u32) -> string {
    allbytes := bytes.buffer_to_bytes(&buffer.buffer)
    slice := allbytes[from : from + length];
    return string(slice);
}

document_init :: proc(doc : ^Document, initial := "") {
    document_buffer_init(&doc.editBuffer, DocumentBufferKind.Edit);
    document_buffer_init(&doc.sourceBuffer, DocumentBufferKind.Source, initial);
}

