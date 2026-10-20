#ifndef NOOL_MEDIA_REMOTE_ADAPTER_H
#define NOOL_MEDIA_REMOTE_ADAPTER_H

/// Entry point installed as a Perl XSUB by NooL App. It never returns: the
/// adapter streams now-playing JSON lines to stdout and exits on stdin EOF.
/// The arguments are the Perl interpreter and CV, which the adapter ignores.
void nool_media_remote_adapter_main(void *interpreter, void *cv);

#endif
