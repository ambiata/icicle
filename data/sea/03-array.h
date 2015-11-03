
typedef struct
{
    iint_t count;
} iarray_struct;
// payload goes straight after

#define ARRAY_OF(t) iarray_t__##t
#define ARRAY_FUN(f,pre) iarray__##pre##f

// I'm not certain there's a point having a different one for each type.
// It makes it look a little better, but I don't think it's any safer.
#define MK_ARRAY_STRUCT(t) typedef iarray_struct* ARRAY_OF(t);

// get payload by advancing pointer by size of struct
// (which should be equivalent to straight after struct fields)
// then casting to t*
#define ARRAY_PAYLOAD(x,t) ((t*)(x+1))


#define MK_ARRAY_LENGTH(t,pre)                                                  \
    static iint_t INLINE ARRAY_FUN(length,pre) (ARRAY_OF(t) arr)                \
    { return arr->count; }

#define MK_ARRAY_EQ(t,pre)                                                      \
    static ibool_t INLINE ARRAY_FUN(eq,pre) (ARRAY_OF(t) x, ARRAY_OF(t) y)      \
    {                                                                           \
        if (x->count != y->count) return ifalse;                                \
        for (iint_t ix = 0; ix != x->count; ++ix) {                             \
            if (!pre##eq(ARRAY_PAYLOAD(x,t)[ix], ARRAY_PAYLOAD(y,t)[ix]))       \
                return ifalse;                                                  \
        }                                                                       \
        return itrue;                                                           \
    }

#define MK_ARRAY_LT(t,pre)                                                      \
    static ibool_t INLINE ARRAY_FUN(lt,pre) (ARRAY_OF(t) x, ARRAY_OF(t) y)      \
    {                                                                           \
        iint_t min = (x->count < y->count) ? x->count : y->count;               \
        for (iint_t ix = 0; ix != min; ++ix) {                                  \
            if (!pre##lt(ARRAY_PAYLOAD(x,t)[ix], ARRAY_PAYLOAD(y,t)[ix]))       \
                return ifalse;                                                  \
        }                                                                       \
        if (x->count < y->count)                                                \
            return itrue;                                                       \
        else                                                                    \
            return ifalse;                                                      \
    }

#define MK_ARRAY_CMP(t,pre,op,ret)                                              \
    static ibool_t INLINE ARRAY_FUN(op,pre) (ARRAY_OF(t) x, ARRAY_OF(t) y)      \
    { return ret ; }                                                            \

#define MK_ARRAY_CMPS(t,pre)                                                    \
    MK_ARRAY_EQ(t,pre)                                                          \
    MK_ARRAY_LT(t,pre)                                                          \
    MK_ARRAY_CMP(t,pre,ne, !ARRAY_FUN(eq,pre) (x,y))                            \
    MK_ARRAY_CMP(t,pre,le,  ARRAY_FUN(lt,pre) (x,y) || ARRAY_FUN(eq,pre) (x,y)) \
    MK_ARRAY_CMP(t,pre,ge, !ARRAY_FUN(lt,pre) (x,y))                            \
    MK_ARRAY_CMP(t,pre,gt, !ARRAY_FUN(le,pre) (x,y))                            \



#define MK_ARRAY_INDEX(t,pre)                                                   \
    static t       INLINE ARRAY_FUN(index,pre) (ARRAY_OF(t) x, iint_t ix)       \
    { return ARRAY_PAYLOAD(x,t)[ix]; }                                          \


#define MK_ARRAY_CREATE(t,pre)                                                  \
    static ARRAY_OF(t)  INLINE ARRAY_FUN(create,pre)                            \
                                        (iallocate_t alloc, iint_t sz)          \
    {                                                                           \
        iint_t bytes     = sizeof(t) * sz + sizeof(iarray_struct);      \
        ARRAY_OF(t)  ret = (ARRAY_OF(t))allocate(alloc, bytes);                 \
        ret->count = sz;                                                        \
        return ret;                                                             \
    }                                                                           \

#define MK_ARRAY_PUT(t,pre)                                                     \
    static iunit_t INLINE ARRAY_FUN(put,pre)   (ARRAY_OF(t) x, iint_t ix, t v)  \
    {                                                                           \
        ARRAY_PAYLOAD(x,t)[ix] = v;                                             \
        return iunit;                                                           \
    }                                                                           \

                                                                                \
                                                                                \
                                                                                \
                                                                                \
                                                                                \



#define MAKE_ARRAY(t,pre)                                                       \
    MK_ARRAY_STRUCT (t)                                                         \
    MK_ARRAY_LENGTH (t,pre)                                                     \
    MK_ARRAY_CMPS   (t,pre)                                                     \
    MK_ARRAY_INDEX  (t,pre)                                                     \
    MK_ARRAY_CREATE (t,pre)                                                     \
    MK_ARRAY_PUT    (t,pre)                                                     \
    // MK_ARRAY_ZIP    (t,pre)                                                     \

// TEMPORARY
typedef void* iallocate_t;
void* allocate(iallocate_t t, iint_t sz);

MAKE_ARRAY(idouble_t,   idouble_)
MAKE_ARRAY(iint_t,      iint_)
MAKE_ARRAY(ierror_t,    ierror_)
MAKE_ARRAY(ibool_t,     ibool_)
MAKE_ARRAY(idate_t,     idate_)
MAKE_ARRAY(iunit_t,     iunit_)
