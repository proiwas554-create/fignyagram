#import <Foundation/Foundation.h>
#include <execinfo.h>
#include <pthread.h>
#include <signal.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>

static pthread_t gMainThread;
static char gPath[1024];
static volatile int gInstalled = 0;

static void fg_sigprof_handler(int sig) {
    (void)sig;
    int fd = open(gPath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        char header[64];
        int n = snprintf(header, sizeof(header), "MAIN THREAD STACK (signal)\n");
        write(fd, header, n);
        void *frames[96];
        int count = backtrace(frames, 96);
        backtrace_symbols_fd(frames, count, fd);
        close(fd);
    }
}

void FignyagramInstallMainThreadSampler(void) {
    if (gInstalled) { return; }
    gInstalled = 1;
    gMainThread = pthread_self();
    NSString *path = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
                      stringByAppendingPathComponent:@"main_thread_stack.txt"];
    strlcpy(gPath, path.fileSystemRepresentation, sizeof(gPath));

    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = fg_sigprof_handler;
    sigemptyset(&action.sa_mask);
    action.sa_flags = SA_RESTART;
    sigaction(SIGPROF, &action, NULL);
}

void FignyagramSampleMainThread(void) {
    if (!gInstalled) { return; }
    pthread_kill(gMainThread, SIGPROF);
}
