#ifndef UTIL_H
#define UTIL_H

#include <ftw.h>

void load(const char* path, void** addr, size_t* size);
void decompress(const void* in, size_t in_size, void** out, size_t* out_size);
int  del(const char* path, const struct stat* sb, int type, struct FTW* ftw);

#endif // UTIL_H
