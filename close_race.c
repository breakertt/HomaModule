// SPDX-License-Identifier: BSD-2-Clause OR GPL-2.0+
/*
 * close_race: close many Homa sockets at once while each still has RPCs in
 * flight, over and over.
 *
 *   close_race server <port> <threads>
 *       echo every request back with a response of the same length
 *   close_race client <server-ip> <port> <threads> <rpcs> <bytes> <rounds> <run-us>
 *       each round, each thread opens a socket and keeps <rpcs> requests of
 *       <bytes> bytes in flight to <server-ip>:<port>+<thread % 4> (run the
 *       server with 4 threads) for <run-us> microseconds, sending a new
 *       request for every response; then all threads close their sockets
 *       at the same time (a barrier releases them together), with <rpcs>
 *       RPCs still in flight on each; prints the number of responses
 *       received, so a server that stops answering shows as a drop
 *
 * Build: gcc -O2 -pthread -I <HomaModule checkout> close_race.c -o close_race
 */
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#include "homa.h"

/* Receive regions: the server's is big enough that its pool never runs out
 * of space (at 64 bpages the out-of-space path has hung the server node with
 * a soft lockup in homa_pool_alloc_msg, a separate problem).
 */
#define CLIENT_REGION (64 * HOMA_BPAGE_SIZE)
#define SERVER_REGION (1024 * HOMA_BPAGE_SIZE)

static struct sockaddr_in server_addr;
static int port0, rpcs, bytes, rounds, run_us;
static pthread_barrier_t barrier;
static long responses;

static void *map_region(size_t size)
{
	void *region = mmap(NULL, size, PROT_READ | PROT_WRITE,
			    MAP_PRIVATE | MAP_ANONYMOUS, 0, 0);

	if (region == MAP_FAILED) {
		perror("mmap");
		exit(1);
	}
	return region;
}

static int homa_socket(void *region, size_t size)
{
	struct homa_rcvbuf_args arg = {(uintptr_t)region, size};
	int fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_HOMA);

	if (fd < 0) {
		perror("socket");
		exit(1);
	}
	if (setsockopt(fd, IPPROTO_HOMA, SO_HOMA_RCVBUF, &arg, sizeof(arg)) < 0) {
		perror("setsockopt(SO_HOMA_RCVBUF)");
		exit(1);
	}
	return fd;
}

static void *server_thread(void *p)
{
	struct sockaddr_in addr = {.sin_family = AF_INET,
				   .sin_port = htons(port0 + (int)(long)p)};
	struct homa_recvmsg_args rargs;
	struct homa_sendmsg_args sargs;
	void *region = map_region(SERVER_REGION);
	struct sockaddr_in src;
	int fd = homa_socket(region, SERVER_REGION);
	char *data = calloc(1, HOMA_MAX_MESSAGE_LENGTH);
	struct msghdr msg;
	struct iovec iov;
	int len;

	if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
		perror("bind");
		exit(1);
	}
	memset(&rargs, 0, sizeof(rargs));
	while (1) {
		memset(&msg, 0, sizeof(msg));
		msg.msg_name = &src;
		msg.msg_namelen = sizeof(src);
		msg.msg_control = &rargs;
		msg.msg_controllen = sizeof(rargs);
		rargs.id = 0;
		len = recvmsg(fd, &msg, 0);  /* returns the previous buffers too */
		if (len < 0)
			continue;
		memset(&sargs, 0, sizeof(sargs));
		sargs.id = rargs.id;
		iov.iov_base = data;
		iov.iov_len = len;
		memset(&msg, 0, sizeof(msg));
		msg.msg_name = &src;
		msg.msg_namelen = sizeof(src);
		msg.msg_iov = &iov;
		msg.msg_iovlen = 1;
		msg.msg_control = &sargs;
		msg.msg_controllen = 0;  /* sendmsg: see the Homa man page */
		sendmsg(fd, &msg, 0);
	}
	return NULL;
}

static void send_request(int fd, struct sockaddr_in *dst, char *data)
{
	struct homa_sendmsg_args sargs;
	struct iovec iov = {data, bytes};
	struct msghdr msg;

	memset(&sargs, 0, sizeof(sargs));
	memset(&msg, 0, sizeof(msg));
	msg.msg_name = dst;
	msg.msg_namelen = sizeof(*dst);
	msg.msg_iov = &iov;
	msg.msg_iovlen = 1;
	msg.msg_control = &sargs;
	msg.msg_controllen = 0;  /* sendmsg: see the Homa man page */
	if (sendmsg(fd, &msg, 0) < 0) {
		perror("sendmsg");
		exit(1);
	}
}

static void *client_thread(void *p)
{
	struct sockaddr_in dst = server_addr;
	struct homa_recvmsg_args rargs;
	char *data = calloc(1, bytes);
	void *region = map_region(CLIENT_REGION);
	struct timespec t0, t;
	struct msghdr msg;
	long received = 0;
	int r, i, fd;

	dst.sin_port = htons(port0 + (int)(long)p % 4);
	for (r = 0; r < rounds; r++) {
		fd = homa_socket(region, CLIENT_REGION);
		memset(&rargs, 0, sizeof(rargs));
		for (i = 0; i < rpcs; i++)
			send_request(fd, &dst, data);
		clock_gettime(CLOCK_MONOTONIC, &t0);
		do {
			memset(&msg, 0, sizeof(msg));
			msg.msg_control = &rargs;
			msg.msg_controllen = sizeof(rargs);
			rargs.id = 0;
			if (recvmsg(fd, &msg, MSG_DONTWAIT) > 0) {
				received++;
				send_request(fd, &dst, data);
			}
			clock_gettime(CLOCK_MONOTONIC, &t);
		} while ((t.tv_sec - t0.tv_sec) * 1000000L +
			 (t.tv_nsec - t0.tv_nsec) / 1000 < run_us);
		pthread_barrier_wait(&barrier);
		close(fd);
		pthread_barrier_wait(&barrier);
	}
	__atomic_add_fetch(&responses, received, __ATOMIC_RELAXED);
	return NULL;
}

int main(int argc, char **argv)
{
	int client = argc == 9 && strcmp(argv[1], "client") == 0;
	pthread_t tid[256];
	long i, n;

	if (!client && !(argc == 4 && strcmp(argv[1], "server") == 0)) {
		fprintf(stderr, "usage: %s server <port> <threads>\n"
			"       %s client <server-ip> <port> <threads> <rpcs> <bytes> <rounds> <run-us>\n",
			argv[0], argv[0]);
		return 1;
	}
	if (client) {
		server_addr.sin_family = AF_INET;
		inet_pton(AF_INET, argv[2], &server_addr.sin_addr);
		port0 = atoi(argv[3]);
		n = atoi(argv[4]);
		rpcs = atoi(argv[5]);
		bytes = atoi(argv[6]);
		rounds = atoi(argv[7]);
		run_us = atoi(argv[8]);
		pthread_barrier_init(&barrier, NULL, n);
	} else {
		port0 = atoi(argv[2]);
		n = atoi(argv[3]);
	}
	if (n < 1 || n > 256)
		return 1;
	for (i = 0; i < n; i++)
		pthread_create(&tid[i], NULL, client ? client_thread : server_thread, (void *)i);
	for (i = 0; i < n; i++)
		pthread_join(tid[i], NULL);
	printf("responses=%ld\n", responses);
	return 0;
}
