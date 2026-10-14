#include <config.h>
#include <errno.h>
#include <netinet/in.h>
#include <stdint.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
#include <ipmitool/ipmi_intf.h>
#include <ipmitool/ipmi.h>
#include <ipmitool/ipmi_sol.h>

int verbose = 0;
int csv_output = 0;
static uint64_t deadline;
static int effect_active;
static int effect_attempted;
static int authentication_failed;
static int (*cancel_check)(const void *);
static const void *cancel_context;

static int cancelled(void) {
    return cancel_check && cancel_check(cancel_context);
}

struct command {
    uint8_t netfn, command, lun, target_address, target_channel;
    uint8_t transit_address, transit_channel;
    uint16_t data_length;
    const uint8_t *data;
};

static uint64_t now_us(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (uint64_t)now.tv_sec * 1000000 + now.tv_nsec / 1000;
}

int __real_select(int, fd_set *, fd_set *, fd_set *, struct timeval *);
ssize_t __real_send(int, const void *, size_t, int);
ssize_t __real_recv(int, void *, size_t, int);
int __real_socket(int, int, int);
void __real_ipmi_intf_session_cleanup(struct ipmi_intf *);
int __real_lanplus_rakp2_hmac_matches(const struct ipmi_session *, const uint8_t *, struct ipmi_intf *);
int __real_lanplus_rakp4_hmac_matches(const struct ipmi_session *, const uint8_t *, struct ipmi_intf *);

int __wrap_socket(int domain, int type, int protocol) {
    int fd = __real_socket(domain, type, protocol);
    if (fd >= FD_SETSIZE) {
        close(fd);
        errno = EMFILE;
        return -1;
    }
    return fd;
}

int __wrap_lanplus_rakp2_hmac_matches(const struct ipmi_session *session,
                                    const uint8_t *hmac, struct ipmi_intf *intf) {
    int valid = __real_lanplus_rakp2_hmac_matches(session, hmac, intf);
    if (!valid) authentication_failed = 1;
    return valid;
}

int __wrap_lanplus_rakp4_hmac_matches(const struct ipmi_session *session,
                                    const uint8_t *hmac, struct ipmi_intf *intf) {
    int valid = __real_lanplus_rakp4_hmac_matches(session, hmac, intf);
    if (!valid) authentication_failed = 1;
    return valid;
}

void __wrap_ipmi_intf_session_cleanup(struct ipmi_intf *intf) {
    if (intf->session) explicit_bzero(intf->session, sizeof(*intf->session));
    __real_ipmi_intf_session_cleanup(intf);
}

/* Bound the unmodified SDK's socket waits to this invocation's total deadline. */
int __wrap_select(int nfds, fd_set *read, fd_set *write, fd_set *error,
                  struct timeval *timeout) {
    uint64_t now = now_us();
    if (now >= deadline) { errno = ETIMEDOUT; return -1; }
    uint64_t remaining = deadline - now;
    struct timeval bound = {remaining / 1000000, remaining % 1000000};
    if (timeout && (uint64_t)timeout->tv_sec * 1000000 + timeout->tv_usec < remaining)
        bound = *timeout;
    if (!cancel_check) return __real_select(nfds, read, write, error, &bound);
    uint64_t end = now + (uint64_t)bound.tv_sec * 1000000 + bound.tv_usec;
    for (;;) {
        if (cancelled()) { errno = ECANCELED; return -1; }
        now = now_us();
        if (now >= end) return 0;
        uint64_t wait = end - now;
        if (wait > 20000) wait = 20000;
        struct timeval poll = {wait / 1000000, wait % 1000000};
        fd_set r, w, e;
        if (read) r = *read;
        if (write) w = *write;
        if (error) e = *error;
        int result = __real_select(nfds, read ? &r : NULL, write ? &w : NULL,
                                   error ? &e : NULL, &poll);
        if (result) {
            if (read) *read = r;
            if (write) *write = w;
            if (error) *error = e;
            return result;
        }
    }
}

ssize_t __wrap_send(int fd, const void *buffer, size_t length, int flags) {
    if (cancelled()) { errno = ECANCELED; return -1; }
    if (now_us() >= deadline) { errno = ETIMEDOUT; return -1; }
    if (effect_active) effect_attempted = 1;
    return __real_send(fd, buffer, length, flags | MSG_DONTWAIT);
}

ssize_t __wrap_recv(int fd, void *buffer, size_t length, int flags) {
    if (cancelled()) { errno = ECANCELED; return -1; }
    if (now_us() >= deadline) { errno = ETIMEDOUT; return -1; }
    /* SDK appends data[received]; reject datagrams that fill its buffer. */
    ssize_t received = __real_recv(fd, buffer, length - 1, flags | MSG_DONTWAIT | MSG_TRUNC);
    if (received >= (ssize_t)length) { errno = EMSGSIZE; return -1; }
    return received;
}

/* SDK diagnostics can contain credentials and raw response bytes. */
void __wrap_lprintf(int level, const char *format, ...) { (void)level; (void)format; }
void __wrap_printbuf(const uint8_t *data, int length, const char *label) {
    (void)data; (void)length; (void)label;
}

static struct ipmi_intf *session(const char *host, uint16_t port, const char *user,
                                  const char *password, uint8_t privilege,
                                  uint8_t cipher, uint64_t timeout_ms) {
    struct ipmi_intf *intf = ipmi_intf_load("lanplus");
    if (!intf) return NULL;
    intf->my_addr = intf->target_addr = 0x20;
    intf->target_lun = intf->target_channel = 0;
    intf->transit_addr = intf->transit_channel = 0;
    ipmi_intf_session_set_hostname(intf, (char *)host);
    ipmi_intf_session_set_username(intf, (char *)user);
    ipmi_intf_session_set_password(intf, (char *)password);
    ipmi_intf_session_set_port(intf, port);
    ipmi_intf_session_set_privlvl(intf, privilege);
    ipmi_intf_session_set_lookupbit(intf, 0x10);
    ipmi_intf_session_set_cipher_suite_id(intf, cipher);
    ipmi_intf_session_set_retry(intf, 1);
    ipmi_intf_session_set_timeout(intf, (timeout_ms + 999) / 1000);
    return intf;
}

static void close_session(struct ipmi_intf *intf) {
    if (intf->opened) intf->close(intf);
    ipmi_cleanup(intf);
    ipmi_intf_session_cleanup(intf);
    explicit_bzero(&intf->ssn_params, sizeof(intf->ssn_params));
}

int skopos_ipmi_command(const char *host, uint16_t port, const char *user,
                        const char *password, uint8_t privilege, uint8_t cipher,
                        uint64_t timeout_ms,
                        const struct command *command, uint8_t *completion,
                        uint8_t *data, uint32_t *length,
                        int (*check)(const void *), const void *context) {
    deadline = now_us() + timeout_ms * 1000;
    effect_active = effect_attempted = authentication_failed = 0;
    cancel_check = check;
    cancel_context = context;
    struct ipmi_intf *intf = session(host, port, user, password, privilege, cipher, timeout_ms);
    if (!intf) { cancel_check = NULL; return 1; }
    int status = 2;
    if (!cancelled() && intf->open(intf) >= 0 && !cancelled() && now_us() < deadline) {
        struct ipmi_rq request = {0};
        request.msg.netfn = command->netfn;
        request.msg.cmd = command->command;
        request.msg.lun = command->lun;
        request.msg.data = (uint8_t *)command->data;
        request.msg.data_len = command->data_length;
        intf->target_lun = command->lun;
        intf->target_addr = command->target_address;
        intf->target_channel = command->target_channel;
        intf->transit_addr = command->transit_address;
        intf->transit_channel = command->transit_channel;
        effect_active = 1;
        struct ipmi_rs *response = intf->sendrecv(intf, &request);
        effect_active = 0;
        status = effect_attempted ? 3 : 2;
        if (response && response->data_len >= 0 && response->data_len < IPMI_BUF_SIZE) {
            *completion = response->ccode;
            *length = response->data_len;
            memcpy(data, response->data, *length);
            status = 0;
        }
    }
    if (status == 2 && cancelled()) status = 6;
    cancel_check = NULL;
    close_session(intf);
    return status == 2 && authentication_failed ? 4 : status;
}

struct sol_exchange {
    uint8_t instance, flags, generate_break;
    uint16_t input_length;
    const uint8_t *input;
    uint32_t read_ms, max_output_bytes;
};

struct sol_outcome {
    int32_t activation_completion, deactivation_completion;
    uint32_t input_acknowledged, output_length, output_bytes;
    uint8_t output_truncated, session_closed;
    uint16_t payload_port;
};

static uint8_t *sol_output;
static uint32_t sol_limit;
static struct sol_outcome *sol_result;
static int sol_invalid_output;

static void sol_capture(struct ipmi_rs *response) {
    if (!response) return;
    if (response->data_len < 0 || response->data_len >= IPMI_BUF_SIZE) {
        sol_invalid_output = 1;
        return;
    }
    uint32_t length = response->data_len;
    sol_result->output_bytes += length;
    uint32_t available = sol_limit - sol_result->output_length;
    if (length > available) { length = available; sol_result->output_truncated = 1; }
    memcpy(sol_output + sol_result->output_length, response->data, length);
    sol_result->output_length += length;
}

static struct ipmi_rs *sol_control(struct ipmi_intf *intf, uint8_t command,
                                  const struct sol_exchange *exchange) {
    uint8_t data[6] = {IPMI_PAYLOAD_TYPE_SOL, exchange->instance, 0, 0, 0, 0};
    if (command == IPMI_ACTIVATE_PAYLOAD) data[2] = exchange->flags;
    struct ipmi_rq request = {0};
    request.msg.netfn = IPMI_NETFN_APP;
    request.msg.cmd = command;
    request.msg.data = data;
    request.msg.data_len = sizeof(data);
    effect_active = 1;
    effect_attempted = 0;
    struct ipmi_rs *response = intf->sendrecv(intf, &request);
    effect_active = 0;
    return response;
}

int skopos_ipmi_sol(const char *host, uint16_t port, const char *user,
                     const char *password, uint8_t privilege, uint8_t cipher,
                     uint64_t timeout_ms,
                     const struct sol_exchange *exchange, uint8_t *output,
                     struct sol_outcome *outcome,
                     int (*check)(const void *), const void *context) {
    uint64_t total_deadline = now_us() + timeout_ms * 1000;
    uint64_t cleanup = timeout_ms / 3;
    if (cleanup > 300) cleanup = 300;
    deadline = total_deadline - cleanup * 1000;
    effect_active = effect_attempted = authentication_failed = 0;
    cancel_check = check;
    cancel_context = context;
    sol_output = output;
    sol_limit = exchange->max_output_bytes;
    sol_result = outcome;
    sol_invalid_output = 0;
    int status = 2, activated = 0, payload_route = 0;
    struct sockaddr_storage control_peer = {0};
    socklen_t control_peer_length = sizeof(control_peer);
    struct ipmi_intf *intf = session(host, port, user, password, privilege, cipher, 1000);
    if (!intf) { cancel_check = NULL; return 1; }
    if (cancelled()) { status = 6; goto done; }
    if (intf->open(intf) < 0) goto done;
    if (cancelled()) { status = 6; goto done; }
    intf->session->sol_data.sol_input_handler = sol_capture;
    struct ipmi_rs *response = sol_control(intf, IPMI_ACTIVATE_PAYLOAD, exchange);
    if (!response) {
        status = effect_attempted ? 3 : (cancelled() ? 6 : 2);
        activated = effect_attempted;
        goto done;
    }
    outcome->activation_completion = response->ccode;
    if (response->ccode) { status = 5; goto done; }
    activated = 1;
    status = 3;
    if (response->data_len != sizeof(struct activate_payload_rsp)) goto done;
    struct activate_payload_rsp activation;
    memcpy(&activation, response->data, sizeof(activation));
    intf->session->sol_data.max_inbound_payload_size =
        activation.inbound_payload_size[0] | activation.inbound_payload_size[1] << 8;
    intf->session->sol_data.port =
        activation.payload_udp_port[0] | activation.payload_udp_port[1] << 8;
    outcome->payload_port = intf->session->sol_data.port;
    if (!intf->session->sol_data.port) goto done;
    if (intf->session->sol_data.port != port) {
        if (getpeername(intf->fd, (struct sockaddr *)&control_peer,
                        &control_peer_length) < 0) goto done;
        struct sockaddr_storage payload_peer = control_peer;
        if (payload_peer.ss_family == AF_INET)
            ((struct sockaddr_in *)&payload_peer)->sin_port = htons(outcome->payload_port);
        else if (payload_peer.ss_family == AF_INET6)
            ((struct sockaddr_in6 *)&payload_peer)->sin6_port = htons(outcome->payload_port);
        else goto done;
        payload_route = 1;
        if (connect(intf->fd, (struct sockaddr *)&payload_peer, control_peer_length) < 0)
            goto done;
    }
    uint32_t chunk = intf->session->sol_data.max_inbound_payload_size;
    if (chunk <= 4) goto done;
    chunk -= 4;
    if (chunk > 255) chunk = 255;
    for (uint32_t offset = 0; offset < exchange->input_length ||
         (!offset && exchange->generate_break);) {
        if (cancelled() || now_us() >= deadline) goto done;
        uint32_t length = exchange->input_length - offset;
        if (length > chunk) length = chunk;
        struct ipmi_v2_payload payload = {0};
        memcpy(payload.payload.sol_packet.data, exchange->input + offset, length);
        payload.payload.sol_packet.character_count = length;
        payload.payload.sol_packet.generate_break = !offset && exchange->generate_break;
        response = intf->send_sol(intf, &payload);
        if (!response || response->session.payloadtype != IPMI_PAYLOAD_TYPE_SOL ||
            response->payload.sol_packet.acked_packet_number != payload.payload.sol_packet.packet_sequence_number ||
            response->payload.sol_packet.accepted_character_count != payload.payload.sol_packet.character_count ||
            response->payload.sol_packet.is_nack || response->payload.sol_packet.transfer_unavailable)
            goto done;
        sol_capture(response);
        outcome->input_acknowledged += length;
        offset += length;
        if (!length) break;
    }
    uint64_t read_until = now_us() + exchange->read_ms * 1000;
    while (now_us() < read_until) {
        if (cancelled() || now_us() >= deadline) goto done;
        fd_set read;
        FD_ZERO(&read);
        FD_SET(intf->fd, &read);
        uint64_t now = now_us();
        if (now >= read_until) break;
        uint64_t remaining = read_until - now;
        struct timeval wait = {remaining / 1000000, remaining % 1000000};
        int ready = __wrap_select(intf->fd + 1, &read, NULL, NULL, &wait);
        if (ready < 0) goto done;
        if (ready > 0) sol_capture(intf->recv_sol(intf));
        if (sol_invalid_output) goto done;
    }
    if (!cancelled()) status = 0;
done:
    if (status == 2 && cancelled()) status = 6;
    if (status == 2 && authentication_failed) status = 4;
    cancel_check = NULL;
    deadline = total_deadline;
    if (payload_route &&
        connect(intf->fd, (struct sockaddr *)&control_peer, control_peer_length) < 0) {
        status = 3;
        activated = 0;
        intf->abort = 1;
    }
    if (activated) {
        struct ipmi_rs *closed = sol_control(intf, IPMI_DEACTIVATE_PAYLOAD, exchange);
        if (closed) {
            outcome->deactivation_completion = closed->ccode;
            outcome->session_closed = closed->ccode == 0;
        }
        if (!outcome->session_closed) status = 3;
    }
    effect_active = 0;
    close_session(intf);
    sol_output = NULL;
    sol_result = NULL;
    return status;
}
