#define _GNU_SOURCE
#define _XOPEN_SOURCE 500

#include <err.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

#include "util.h"

int main(int argc, char** argv) {
	(void) argc;
	puts("[1;32mWelcome to goblin![m");

	puts("[1;33mLoading essential kernel modules...[m");
	FILE* modlist = fopen(argv[1], "r");
	if(modlist == NULL) err(1, "could not open %s", argv[1]);

	char*   path = NULL;
	size_t  n    = 0;
	ssize_t l    = 0;
	while((l = getline(&path, &n, modlist)) > 0) {
		path[l - 1] = 0;

		void*  addr_xz = NULL;
		size_t size_xz = 0;
		load(path, &addr_xz, &size_xz);

		void*  addr = NULL;
		size_t size = 0;
		decompress(addr_xz, size_xz, &addr, &size);
		munmap(addr_xz, size_xz);

		if(syscall(SYS_init_module, addr, size, "") < 0)
			err(1, "init_module failed");
		free(addr);
	}

	free(path);
	fclose(modlist);

	puts("[1;33mCleaning up initramfs...[m");
	nftw("/", del, 100, FTW_DEPTH);

	puts("[1;33mMounting root filesystem...[m");

	// create directories
	if(mkdir("ro", 0755) < 0) err(1, "mkdir ro failed");
	if(mkdir("rw", 0755) < 0) err(1, "mkdir rw failed");
	if(mkdir("wk", 0755) < 0) err(1, "mkdir wk failed");
	if(mkdir("ov", 0755) < 0) err(1, "mkdir ov failed");

	// mount filesystems
	if(mount("rootfs", "ro", "9p", 0, "trans=virtio") < 0)
		err(1, "mount rootfs on ro failed");
	if(mount(
		   "rootfs", "ov", "overlay", 0, "lowerdir=ro,upperdir=rw,workdir=wk"
	   ) < 0)
		err(1, "mount rootfs overlay failed");

	puts("[1;33mSwitching over...[m");
	if(chdir("ov") < 0) err(1, "chdir failed");
	if(chroot(".") < 0) err(1, "chroot failed");
	execl("init", "init", NULL);
	err(1, "exec init failed");
}
