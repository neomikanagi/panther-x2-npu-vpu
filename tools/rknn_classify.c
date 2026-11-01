/* NPU acceptance test: run a real image through an RKNN classifier and print
 * the top-5 classes and the NPU time. Input is a binary PPM (P6) at the
 * model's input size, e.g. from `djpeg -pnm dog_224x224.jpg`.
 *   gcc -O2 -o rknn_classify rknn_classify.c -I. -L. -lrknnrt
 *   ./rknn_classify mobilenet_v1.rknn dog.ppm [loops]
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "rknn_api.h"

static void *read_file(const char *path, long *size)
{
	FILE *f = fopen(path, "rb");
	void *buf;

	if (!f)
		return NULL;
	fseek(f, 0, SEEK_END);
	*size = ftell(f);
	rewind(f);
	buf = malloc(*size);
	if (buf && fread(buf, 1, *size, f) != (size_t)*size) {
		free(buf);
		buf = NULL;
	}
	fclose(f);
	return buf;
}

/* Minimal P6 reader: returns a pointer into buf at the pixel data. */
static uint8_t *ppm_pixels(uint8_t *buf, long size, int *w, int *h)
{
	int maxval, n = 0;

	if (sscanf((char *)buf, "P6 %d %d %d%n", w, h, &maxval, &n) != 3 || maxval != 255)
		return NULL;
	n++; /* single whitespace after maxval */
	if (n + (long)*w * *h * 3 > size)
		return NULL;
	return buf + n;
}

static double now_ms(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

int main(int argc, char **argv)
{
	rknn_context ctx = 0;
	rknn_input_output_num io;
	rknn_tensor_attr in_attr, out_attr;
	rknn_sdk_version ver;
	rknn_perf_run perf;
	rknn_input input;
	rknn_output output;
	long msize, isize;
	int w, h, loops, i, k, ret;
	void *model;
	uint8_t *img, *pix;
	float *prob;
	double t0, t_total = 0;

	if (argc < 3) {
		fprintf(stderr, "usage: %s model.rknn image.ppm [loops]\n", argv[0]);
		return 2;
	}
	loops = argc > 3 ? atoi(argv[3]) : 10;
	model = read_file(argv[1], &msize);
	img = read_file(argv[2], &isize);
	if (!model || !img) {
		perror("read");
		return 1;
	}
	pix = ppm_pixels(img, isize, &w, &h);
	if (!pix) {
		fprintf(stderr, "bad PPM\n");
		return 1;
	}

	ret = rknn_init(&ctx, model, msize, RKNN_FLAG_COLLECT_PERF_MASK, NULL);
	if (ret < 0) {
		fprintf(stderr, "rknn_init failed: %d\n", ret);
		return 1;
	}
	rknn_query(ctx, RKNN_QUERY_SDK_VERSION, &ver, sizeof(ver));
	printf("sdk api: %s  driver: %s\n", ver.api_version, ver.drv_version);
	rknn_query(ctx, RKNN_QUERY_IN_OUT_NUM, &io, sizeof(io));
	memset(&in_attr, 0, sizeof(in_attr));
	rknn_query(ctx, RKNN_QUERY_INPUT_ATTR, &in_attr, sizeof(in_attr));
	memset(&out_attr, 0, sizeof(out_attr));
	rknn_query(ctx, RKNN_QUERY_OUTPUT_ATTR, &out_attr, sizeof(out_attr));
	printf("model: %u in / %u out, input %ux%ux%u, output %u elems\n",
	       io.n_input, io.n_output, in_attr.dims[1], in_attr.dims[2], in_attr.dims[3],
	       out_attr.n_elems);
	if (in_attr.dims[1] != (uint32_t)h || in_attr.dims[2] != (uint32_t)w) {
		fprintf(stderr, "image is %dx%d, model wants %ux%u\n", w, h, in_attr.dims[2], in_attr.dims[1]);
		return 1;
	}

	memset(&input, 0, sizeof(input));
	input.index = 0;
	input.type = RKNN_TENSOR_UINT8;
	input.fmt = RKNN_TENSOR_NHWC;
	input.size = w * h * 3;
	input.buf = pix;

	for (i = 0; i < loops; i++) {
		rknn_inputs_set(ctx, 1, &input);
		t0 = now_ms();
		ret = rknn_run(ctx, NULL);
		t_total += now_ms() - t0;
		if (ret < 0) {
			fprintf(stderr, "rknn_run failed: %d\n", ret);
			return 1;
		}
	}
	rknn_query(ctx, RKNN_QUERY_PERF_RUN, &perf, sizeof(perf));
	printf("rknn_run: %.2f ms avg over %d runs (NPU %ld us last run)\n",
	       t_total / loops, loops, (long)perf.run_duration);

	memset(&output, 0, sizeof(output));
	output.want_float = 1;
	rknn_outputs_get(ctx, 1, &output, NULL);
	prob = output.buf;
	printf("top5:");
	for (k = 0; k < 5; k++) {
		uint32_t best = 0;

		for (i = 1; i < (int)out_attr.n_elems; i++)
			if (prob[i] > prob[best])
				best = i;
		printf(" [%u] %.4f", best, prob[best]);
		prob[best] = -1e9f;
	}
	printf("\n");
	rknn_outputs_release(ctx, 1, &output);
	rknn_destroy(ctx);
	return 0;
}
