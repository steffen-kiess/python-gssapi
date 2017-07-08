GSSAPI="BASE"  # This ensures that a full module is generated by Cython

from libc.stdlib cimport malloc, calloc, free
from libc.string cimport memcpy

from gssapi.raw.cython_types cimport *
from gssapi.raw.sec_contexts cimport SecurityContext

from gssapi.raw.misc import GSSError
from gssapi.raw import types as gssapi_types
from gssapi.raw.named_tuples import IOVUnwrapResult, WrapResult, UnwrapResult
from collections import namedtuple

from enum import IntEnum
import six
from gssapi.raw._enum_extensions import ExtendableEnum

if six.PY2:
    from collections import Sequence
else:
    from collections.abc import Sequence


cdef extern from "python_gssapi_ext.h":
    # NB(directxman12): this wiki page has a different argument order
    #                   than the header file, and uses size_t instead of int
    #                   (this file matches the header file)
    OM_uint32 gss_wrap_iov(OM_uint32 *min_stat, gss_ctx_id_t ctx_handle,
                           int conf_req_flag, gss_qop_t qop_req, int *conf_ret,
                           gss_iov_buffer_desc *iov, int iov_count) nogil

    OM_uint32 gss_unwrap_iov(OM_uint32 *min_stat, gss_ctx_id_t ctx_handle,
                             int* conf_ret, gss_qop_t *qop_ret,
                             gss_iov_buffer_desc *iov, int iov_count) nogil

    OM_uint32 gss_wrap_iov_length(OM_uint32 *min_stat, gss_ctx_id_t ctx_handle,
                                  int conf_req, gss_qop_t qop_req,
                                  int *conf_ret, gss_iov_buffer_desc *iov,
                                  int iov_count) nogil

    OM_uint32 gss_release_iov_buffer(OM_uint32 *min_stat,
                                     gss_iov_buffer_desc *iov,
                                     int iov_count) nogil

    OM_uint32 gss_wrap_aead(OM_uint32 *min_stat, gss_ctx_id_t ctx_handle,
                            int conf_req, gss_qop_t qop_req,
                            gss_buffer_t input_assoc_buffer,
                            gss_buffer_t input_payload_buffer, int *conf_ret,
                            gss_buffer_t output_message_buffer) nogil

    OM_uint32 gss_unwrap_aead(OM_uint32 *min_stat, gss_ctx_id_t ctx_handle,
                              gss_buffer_t input_message_buffer,
                              gss_buffer_t input_assoc_buffer,
                              gss_buffer_t output_payload_buffer,
                              int *conf_ret, gss_qop_t *qop_ret) nogil

    gss_iov_buffer_t GSS_C_NO_IOV_BUFFER

    OM_uint32 GSS_IOV_BUFFER_TYPE_EMPTY
    OM_uint32 GSS_IOV_BUFFER_TYPE_DATA
    OM_uint32 GSS_IOV_BUFFER_TYPE_HEADER
    OM_uint32 GSS_IOV_BUFFER_TYPE_MECH_PARAMS
    OM_uint32 GSS_IOV_BUFFER_TYPE_TRAILER
    OM_uint32 GSS_IOV_BUFFER_TYPE_PADDING
    OM_uint32 GSS_IOV_BUFFER_TYPE_STREAM
    OM_uint32 GSS_IOV_BUFFER_TYPE_SIGN_ONLY

    OM_uint32 GSS_IOV_BUFFER_FLAG_MASK
    OM_uint32 GSS_IOV_BUFFER_FLAG_ALLOCATE
    OM_uint32 GSS_IOV_BUFFER_FLAG_ALLOCATED

    # a few more are in the enum extension file


class IOVBufferType(IntEnum, metaclass=ExtendableEnum):
    """
    IOV Buffer Types

    This IntEnum represent GSSAPI IOV buffer
    types to be used with the IOV methods.

    The numbers behind the values correspond directly
    to their C counterparts.
    """

    empty = GSS_IOV_BUFFER_TYPE_EMPTY
    data = GSS_IOV_BUFFER_TYPE_DATA
    header = GSS_IOV_BUFFER_TYPE_HEADER
    mech_params = GSS_IOV_BUFFER_TYPE_MECH_PARAMS
    trailer = GSS_IOV_BUFFER_TYPE_TRAILER
    padding = GSS_IOV_BUFFER_TYPE_PADDING
    stream = GSS_IOV_BUFFER_TYPE_STREAM
    sign_only = GSS_IOV_BUFFER_TYPE_SIGN_ONLY


IOVBuffer = namedtuple('IOVBuffer', ['type', 'allocate', 'value'])


cdef class IOV:
    """A GSSAPI IOV"""
    # defined in ext_dce.pxd

    # cdef int iov_len
    # cdef bint c_changed

    # cdef gss_iov_buffer_desc *_iov
    # cdef bint _unprocessed
    # cdef list _buffs

    AUTO_ALLOC_BUFFERS = set([IOVBufferType.header, IOVBufferType.padding,
                              IOVBufferType.trailer])

    def __init__(IOV self, *args, std_layout=True, auto_alloc=True):
        self._unprocessed = True
        self.c_changed = False

        self._buffs = []

        if std_layout:
            self._buffs.append(IOVBuffer(IOVBufferType.header,
                                         auto_alloc, None))

        cdef char *val_copy
        for buff_desc in args:
            if isinstance(buff_desc, tuple):
                if len(buff_desc) > 3 or len(buff_desc) < 2:
                    raise ValueError("Buffer description tuples must be "
                                     "length 2 or 3")

                buff_type = buff_desc[0]

                if len(buff_desc) == 2:
                    if buff_type in self.AUTO_ALLOC_BUFFERS:
                        alloc = buff_desc[1]
                        data = None
                    else:
                        data = buff_desc[1]
                        alloc = False
                else:
                    (buff_type, alloc, data) = buff_desc

                self._buffs.append(IOVBuffer(buff_type, alloc, data))
            elif isinstance(buff_desc, bytes):  # assume type data
                val = buff_desc
                self._buffs.append(IOVBuffer(IOVBufferType.data, False, val))
            else:
                alloc = False
                if buff_desc in self.AUTO_ALLOC_BUFFERS:
                    alloc = auto_alloc

                self._buffs.append(IOVBuffer(buff_desc, alloc, None))

        if std_layout:
            self._buffs.append(IOVBuffer(IOVBufferType.padding, auto_alloc,
                                         None))
            self._buffs.append(IOVBuffer(IOVBufferType.trailer, auto_alloc,
                                         None))

    cdef gss_iov_buffer_desc* __cvalue__(IOV self) except NULL:
        cdef OM_uint32 tmp_min_stat
        cdef int i
        if self._unprocessed:
            if self._iov is not NULL:
                gss_release_iov_buffer(&tmp_min_stat, self._iov, self.iov_len)
                free(self._iov)

            self.iov_len = len(self._buffs)
            self._iov = <gss_iov_buffer_desc *>calloc(
                self.iov_len, sizeof(gss_iov_buffer_desc))
            if self._iov is NULL:
                raise MemoryError("Cannot calloc for IOV buffer array")

            for i in range(self.iov_len):
                buff = self._buffs[i]
                self._iov[i].type = buff.type

                if buff.allocate:
                    self._iov[i].type |= GSS_IOV_BUFFER_FLAG_ALLOCATE
                elif buff.allocate is None:
                    self._iov[i].type |= GSS_IOV_BUFFER_FLAG_ALLOCATED

                if buff.value is None:
                    self._iov[i].buffer.length = 0
                    self._iov[i].buffer.value = NULL
                else:
                    self._iov[i].buffer.length = len(buff.value)
                    self._iov[i].buffer.value = <char *>malloc(
                        self._iov[i].buffer.length)
                    if self._iov[i].buffer.value is NULL:
                        raise MemoryError("Cannot malloc for buffer value")

                    memcpy(self._iov[i].buffer.value, <char *>buff.value,
                           self._iov[i].buffer.length)

        return self._iov

    cdef _recreate_python_values(IOV self):
        cdef i
        cdef bint val_change = False
        cdef size_t new_len
        for i in range(self.iov_len):
            old_type = self._buffs[i].type

            if self._iov[i].buffer.value is NULL:
                if self._iov[i].buffer.length == 0:
                    new_val = None
                else:
                    new_len = self._iov[i].buffer.length
                    new_val = b'\x00' * new_len
            else:
                new_len = self._iov[i].buffer.length
                new_val = self._iov[i].buffer.value[:new_len]

            alloc = False
            if self._iov[i].type & GSS_IOV_BUFFER_FLAG_ALLOCATE:
                alloc = True

            # NB(directxman12): GSSAPI (at least in MIT krb5) doesn't
            # unset the allocate flag (because it's an "input flag",
            # so this needs to come second and be separate
            if self._iov[i].type & GSS_IOV_BUFFER_FLAG_ALLOCATED:
                alloc = None

            self._buffs[i] = IOVBuffer(old_type, alloc, new_val)

        self.c_changed = False

    def __getitem__(IOV self, ind):
        if self.c_changed:
            self._recreate_python_values()

        return self._buffs[ind]

    def __len__(IOV self):
        if self.c_changed:
            self._recreate_python_values()

        return len(self._buffs)

    def __iter__(IOV self):
        if self.c_changed:
            self._recreate_python_values()

        for val in self._buffs:
            yield val

    def __contains__(IOV self, item):
        if self.c_changed:
            self._recreate_python_values()

        return item in self._buffs

    def __reversed__(IOV self):
        if self.c_changed:
            self._recreate_python_values()

        for val in reversed(self._buffs):
            yield val

    def index(IOV self, value):
        for i, v in enumerate(self):
            if v == value:
                return i

        raise ValueError

    def count(IOV self, value):
        return sum(1 for v in self if v == value)

    def __repr__(IOV self):
        if self.c_changed:
            self._recreate_python_values()

        return "<{module}.{name} {buffs}>".format(
            module=type(self).__module__, name=type(self).__name__,
            buffs=repr(self._buffs))

    def __str__(IOV self):
        buff_strs = []
        for buff in self:
            type_val = str(buff.type).split('.')[1].upper()
            if buff.value is None:
                auto_alloc = buff.allocate
                if auto_alloc:
                    buff_strs.append(type_val + "(allocate)")
                else:
                    buff_strs.append(type_val + "(empty)")
            else:
                if buff.allocate is None:
                    alloc_str = ", allocated"
                else:
                    alloc_str = ""
                buff_strs.append("{0}({1!r}{2})".format(type_val,
                                                        buff.value, alloc_str))

        return "<IOV {0}>".format(' | '.join(buff_strs))

    def __dealloc__(IOV self):
        cdef OM_uint32 tmp_min_stat
        cdef int i
        if self._iov is not NULL:
            gss_release_iov_buffer(&tmp_min_stat, self._iov, self.iov_len)

            for i in range(self.iov_len):
                if self._iov[i].buffer.value is not NULL:
                    free(self._iov[i].buffer.value)

            free(self._iov)


def wrap_iov(SecurityContext context not None, IOV message not None,
             confidential=True, qop=None):
    """
    wrap_iov(context, message, confidential=True, qop=None)
    Wrap/Encrypt an IOV message.

    This method wraps or encrypts an IOV message.  The allocate
    parameter of the :class:`IOVBuffer` objects in the :class:`IOV`
    indicates whether or not that particular buffer should be
    automatically allocated (for use with padding, header, and
    trailer buffers).

    Warning:
        This modifies the input :class:`IOV`.

    Args:
        context (SecurityContext): the current security context
        message (IOV): an :class:`IOV` containing the message
        confidential (bool): whether or not to encrypt the message (True),
            or just wrap it with a MIC (False)
        qop (int): the desired Quality of Protection
            (or None for the default QoP)

    Returns:
        bool: whether or not confidentiality was actually used

    Raises:
        GSSError
    """

    cdef int conf_req = confidential
    cdef gss_qop_t qop_req = qop if qop is not None else GSS_C_QOP_DEFAULT
    cdef int conf_used

    cdef gss_iov_buffer_desc *res_arr = message.__cvalue__()

    cdef OM_uint32 maj_stat, min_stat

    with nogil:
        maj_stat = gss_wrap_iov(&min_stat, context.raw_ctx, conf_req, qop_req,
                                &conf_used, res_arr, message.iov_len)

    if maj_stat == GSS_S_COMPLETE:
        message.c_changed = True
        return <bint>conf_used
    else:
        raise GSSError(maj_stat, min_stat)


def unwrap_iov(SecurityContext context not None, IOV message not None):
    """
    unwrap_iov(context, message)
    Unwrap/Decrypt an IOV message.

    This method uwraps or decrypts an IOV message.  The allocate
    parameter of the :class:`IOVBuffer` objects in the :class:`IOV`
    indicates whether or not that particular buffer should be
    automatically allocated (for use with padding, header, and
    trailer buffers).

    As a special case, you may pass an entire IOV message
    as a single 'stream'.  In this case, pass a buffer type
    of :attr:`IOVBufferType.stream` followed by a buffer type of
    :attr:`IOVBufferType.data`.  The former should contain the
    entire IOV message, while the latter should be empty.

    Warning:
        This modifies the input :class:`IOV`.

    Args:
        context (SecurityContext): the current security context
        message (IOV): an :class:`IOV` containing the message

    Returns:
        IOVUnwrapResult: whether or not confidentiality was used,
            and the QoP used.

    Raises:
        GSSError
    """

    cdef int conf_used
    cdef gss_qop_t qop_used
    cdef gss_iov_buffer_desc *res_arr = message.__cvalue__()

    cdef OM_uint32 maj_stat, min_stat

    with nogil:
        maj_stat = gss_unwrap_iov(&min_stat, context.raw_ctx, &conf_used,
                                  &qop_used, res_arr, message.iov_len)

    if maj_stat == GSS_S_COMPLETE:
        message.c_changed = True
        return IOVUnwrapResult(<bint>conf_used, qop_used)
    else:
        raise GSSError(maj_stat, min_stat)


def wrap_iov_length(SecurityContext context not None, IOV message not None,
                    confidential=True, qop=None):
    """
    wrap_iov_length(context, message, confidential=True, qop=None)
    Appropriately size padding, trailer, and header IOV buffers.

    This method sets the length values on the IOV buffers.  You
    should already have data provided for the data (and sign-only)
    buffer(s) so that padding lengths can be appropriately computed.

    In Python terms, this will result in an appropriately sized
    `bytes` object consisting of all zeros.

    Warning:
        This modifies the input :class:`IOV`.

    Args:
        context (SecurityContext): the current security context
        message (IOV): an :class:`IOV` containing the message

    Returns:
        WrapResult: a list of :class:IOVBuffer` objects, and whether or not
            encryption was actually used

    Raises:
        GSSError
    """

    cdef int conf_req = confidential
    cdef gss_qop_t qop_req = qop if qop is not None else GSS_C_QOP_DEFAULT
    cdef int conf_used

    cdef gss_iov_buffer_desc *res_arr = message.__cvalue__()

    cdef OM_uint32 maj_stat, min_stat

    with nogil:
        maj_stat = gss_wrap_iov_length(&min_stat, context.raw_ctx,
                                       conf_req, qop_req,
                                       &conf_used, res_arr, message.iov_len)

    if maj_stat == GSS_S_COMPLETE:
        message.c_changed = True
        return <bint>conf_used
    else:
        raise GSSError(maj_stat, min_stat)


def wrap_aead(SecurityContext context not None, bytes message not None,
              bytes associated=None, confidential=True, qop=None):
    """
    wrap_aead(context, message, associated=None, confidential=True, qop=None)
    Wrap/Encrypt an AEAD message.

    This method takes an input message and associated data,
    and outputs and AEAD message.

    Args:
        context (SecurityContext): the current security context
        message (bytes): the message to wrap or encrypt
        associated (bytes): associated data to go with the message
        confidential (bool): whether or not to encrypt the message (True),
            or just wrap it with a MIC (False)
        qop (int): the desired Quality of Protection
            (or None for the default QoP)

    Returns:
        WrapResult: the wrapped/encrypted total message, and whether or not
            encryption was actually used

    Raises:
        GSSError
    """

    cdef int conf_req = confidential
    cdef gss_qop_t qop_req = qop if qop is not None else GSS_C_QOP_DEFAULT
    cdef gss_buffer_desc message_buffer = gss_buffer_desc(len(message),
                                                          message)

    cdef gss_buffer_t assoc_buffer_ptr = GSS_C_NO_BUFFER
    cdef gss_buffer_desc assoc_buffer
    if associated is not None:
        assoc_buffer = gss_buffer_desc(len(associated), associated)
        assoc_buffer_ptr = &assoc_buffer

    cdef int conf_used
    # GSS_C_EMPTY_BUFFER
    cdef gss_buffer_desc output_buffer = gss_buffer_desc(0, NULL)

    cdef OM_uint32 maj_stat, min_stat

    with nogil:
        maj_stat = gss_wrap_aead(&min_stat, context.raw_ctx, conf_req, qop_req,
                                 assoc_buffer_ptr, &message_buffer,
                                 &conf_used, &output_buffer)

    if maj_stat == GSS_S_COMPLETE:
        output_message = output_buffer.value[:output_buffer.length]
        gss_release_buffer(&min_stat, &output_buffer)
        return WrapResult(output_message, <bint>conf_used)
    else:
        raise GSSError(maj_stat, min_stat)


def unwrap_aead(SecurityContext context not None, bytes message not None,
                bytes associated=None):
    """
    unwrap_aead(context, message, associated=None)
    Unwrap/Decrypt an AEAD message.

    This method takes an encrpyted/wrapped AEAD message and some associated
    data, and returns an unwrapped/decrypted message.

    Args:
        context (SecurityContext): the current security context
        message (bytes): the AEAD message to unwrap or decrypt
        associated (bytes): associated data that goes with the message

    Returns:
        UnwrapResult: the unwrapped/decrypted message, whether or on
            encryption was used, and the QoP used

    Raises:
        GSSError
    """

    cdef gss_buffer_desc input_buffer = gss_buffer_desc(len(message), message)

    cdef gss_buffer_t assoc_buffer_ptr = GSS_C_NO_BUFFER
    cdef gss_buffer_desc assoc_buffer
    if associated is not None:
        assoc_buffer = gss_buffer_desc(len(associated), associated)
        assoc_buffer_ptr = &assoc_buffer

    # GSS_C_EMPTY_BUFFER
    cdef gss_buffer_desc output_buffer = gss_buffer_desc(0, NULL)
    cdef int conf_state
    cdef gss_qop_t qop_state

    cdef OM_uint32 maj_stat, min_stat

    with nogil:
        maj_stat = gss_unwrap_aead(&min_stat, context.raw_ctx, &input_buffer,
                                   assoc_buffer_ptr, &output_buffer,
                                   &conf_state, &qop_state)

    if maj_stat == GSS_S_COMPLETE:
        output_message = output_buffer.value[:output_buffer.length]
        gss_release_buffer(&min_stat, &output_buffer)
        return UnwrapResult(output_message, <bint>conf_state, qop_state)
    else:
        raise GSSError(maj_stat, min_stat)