// Native win32 Ruby scipt launcher

#include <stdio.h>
#include <process.h>
#include <windows.h>

#define SZ 32767

int main(int _argc, char** _argv) {
	int i;
	#ifndef NDEBUG
		i = 0;
		printf("argc = %d\n", _argc);
		while(i < _argc) {
			printf("^ %s\n", _argv[i++]);
		}
	#endif
	char* root = malloc(SZ*sizeof(char));
	GetModuleFileName(NULL, root, SZ);
	i = strlen(root);
	while(root[--i] != '\\'); while(root[--i] != '\\'); root[i] = '\0';
	char* ruby = malloc(SZ*sizeof(char));
	snprintf(ruby, SZ, "%s\\ruby\\bin\\ruby.exe", root); // Path to Ruby interpreter
	char* script = malloc(SZ*sizeof(char));
	snprintf(script, SZ, "%s\\ruby\\bin\\rockup", root); // Path to Ruby script
	char** argv = calloc(SZ, sizeof(char*));
	i = 0;
	argv[i++] = ruby;
	argv[i++] = script;
	for(int x = 1; x < _argc; ++x) {
		argv[i++] = _argv[x];
	}
	#ifndef NDEBUG
		i = 0;
		while(argv[i]) {
			printf("> %s\n", argv[i++]);
		}
	#endif
	return _spawnvp(_P_WAIT, argv[0], argv);
}          