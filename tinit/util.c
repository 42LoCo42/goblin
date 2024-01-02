#define _XOPEN_SOURCE 500

#include <err.h>
#include <fcntl.h>
#include <lzma.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

#include "util.h"

void load(const char* path, void** addr, size_t* size) {
	struct stat info = {0};
	if(stat(path, &info) < 0) err(1, "could not stat");
	*size = info.st_size;

	int fd = open(path, O_RDONLY, 0);
	if(fd < 0) err(1, "could not open");

	*addr = mmap(NULL, *size, PROT_READ, MAP_PRIVATE, fd, 0);
	if(*addr == NULL) err(1, "could not mmap");
	close(fd);
}

void decompress(const void* in, size_t in_size, void** out, size_t* out_size) {
	lzma_stream stream = LZMA_STREAM_INIT;
	if(lzma_stream_decoder(&stream, UINT64_MAX, 0) != LZMA_OK)
		err(1, "could not init LZMA decoder");

	size_t out_buffer_size = 8192;
	*out                   = malloc(out_buffer_size);
	if(*out == NULL) err(1, "could not alloc out buffer");

	stream.next_in   = in;
	stream.avail_in  = in_size;
	stream.next_out  = *out;
	stream.avail_out = out_buffer_size;

	lzma_ret ret = LZMA_OK;
	while(ret == LZMA_OK) {
		ret = lzma_code(&stream, LZMA_RUN);
		if(stream.avail_out == 0) {
			out_buffer_size *= 2;
			*out = realloc(*out, out_buffer_size);
			if(*out == NULL) err(1, "could not realloc out buffer");

			stream.next_out  = *out + stream.total_out;
			stream.avail_out = out_buffer_size - stream.total_out;
		}
	}

	if(ret != LZMA_STREAM_END) {
		warn("decompression failed");
		free(*out);
		exit(1);
	}

	*out_size = stream.total_out;
	lzma_end(&stream);
}

int del(const char* path, const struct stat* sb, int type, struct FTW* ftw) {
	(void) sb;
	(void) ftw;

	switch(type) {
	case FTW_F:
		unlink(path);
		break;
	case FTW_DP:
		rmdir(path);
		break;
	}

	return 0;
}
