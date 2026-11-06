#ifndef TC_NETWORK_PROBE_H
#define TC_NETWORK_PROBE_H
#include <string.h>
#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#else
#include <sys/socket.h>
#include <sys/time.h>
#include <netdb.h>
#include <unistd.h>
#endif
/* A read-only, one-packet NTP query. Does not set the system clock. */
static inline int tc_native_ntp_exchange(const unsigned char *request, int request_size,
                                        unsigned char *output, int capacity, int *received) {
    if(!request||request_size!=48||!output||capacity<48||!received)return 0;
    *received=0;
#ifdef _WIN32
    WSADATA data;if(WSAStartup(0x0202,&data)!=0)return 0;
    SOCKET descriptor=INVALID_SOCKET;
#else
    int descriptor=-1;
#endif
    struct addrinfo hints,*addresses=NULL;memset(&hints,0,sizeof(hints));
    hints.ai_family=AF_UNSPEC;hints.ai_socktype=SOCK_DGRAM;hints.ai_protocol=IPPROTO_UDP;
    if(getaddrinfo("time.cloudflare.com","123",&hints,&addresses)!=0)goto done;
    for(struct addrinfo *address=addresses;address;address=address->ai_next){
        descriptor=socket(address->ai_family,address->ai_socktype,address->ai_protocol);
#ifdef _WIN32
        if(descriptor==INVALID_SOCKET)continue;
        DWORD timeout=4000;setsockopt(descriptor,SOL_SOCKET,SO_RCVTIMEO,(char*)&timeout,sizeof(timeout));
        setsockopt(descriptor,SOL_SOCKET,SO_SNDTIMEO,(char*)&timeout,sizeof(timeout));
        if(connect(descriptor,address->ai_addr,(int)address->ai_addrlen)==0)break;
        closesocket(descriptor);descriptor=INVALID_SOCKET;
#else
        if(descriptor<0)continue;
        struct timeval timeout={4,0};setsockopt(descriptor,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
        setsockopt(descriptor,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));
        if(connect(descriptor,address->ai_addr,address->ai_addrlen)==0)break;
        close(descriptor);descriptor=-1;
#endif
    }
    freeaddrinfo(addresses);addresses=NULL;
#ifdef _WIN32
    if(descriptor==INVALID_SOCKET)goto done;
#else
    if(descriptor<0)goto done;
#endif
    if(send(descriptor,(const char*)request,request_size,0)==request_size){
        int count=(int)recv(descriptor,(char*)output,capacity,0);if(count>=48)*received=count;
    }
done:
    if(addresses)freeaddrinfo(addresses);
#ifdef _WIN32
    if(descriptor!=INVALID_SOCKET)closesocket(descriptor);WSACleanup();
#else
    if(descriptor>=0)close(descriptor);
#endif
    return *received>=48;
}
#endif
