module crypto.blake2.blake2b;

// only supported sse2
// to do: sse3, sse4, avx

import core.stdc.string: memset, memcpy;
import inteli.types;

import crypto.blake2.impl;
import crypto.blake2.blake2b_round;
import crypto.utils;


static this()
{
    import core.cpuid: sse2;
    assert(sse2(), "Requires support for SSE2 processor commands");
}


immutable B160 = 20;
immutable B256 = 32;
immutable B384 = 48;
immutable B512 = 64;

nothrow @nogc
{

    enum CONSTANT
    {
        BLOCKBYTES    = 128,
        OUTBYTES      = 64,
        KEYBYTES      = 64,
        SALTBYTES     = 16,
        PERSONALBYTES = 16
    }

    struct State
    {
        ulong[8] h;
        ulong[2] t;
        ulong[2] f;
        ubyte[CONSTANT.BLOCKBYTES] buf;
        size_t   buflen;
        size_t   outlen;
        ubyte    lastNode;
    }

    State state;


    struct Param
    {
        align(1):

        ubyte       digestLength; /* 1 */
        ubyte       keyLength;    /* 2 */
        ubyte       fanout;       /* 3 */
        ubyte       depth;        /* 4 */
        uint        leafLength;   /* 8 */
        uint        nodeOffset;   /* 12 */
        uint        xofLength;    /* 16 */
        ubyte       nodeDepth;    /* 17 */
        ubyte       innerLength;  /* 18 */
        ubyte[14]   reserved;      /* 32 */
        ubyte[CONSTANT.SALTBYTES]     salt;     /* 48 */
        ubyte[CONSTANT.PERSONALBYTES] personal; /* 64 */
    }

    private Param param;

    private immutable ulong[8] IV =
    [
        0x6a09e667f3bcc908, 0xbb67ae8584caa73b,
        0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
        0x510e527fade682d1, 0x9b05688c2b3e6c1f,
        0x1f83d9abfb41bd6b, 0x5be0cd19137e2179
    ];


    private void setLastnode(State *S)
    {
        S.f[1] = ulong.max;
    }
    private int isLastblock(const State *S)
    {
        return S.f[0] != 0;
    }

    private void setLastblock(State *S)
    {
        if (S.lastNode) setLastnode(S);

        S.f[0] = ulong.max;
    }

    private void incrementCounter(State *S, ulong inc)
    {
        S.t[0] += inc;
        S.t[1] += (S.t[0] < inc);
    }


    private void compress(State *S, const ubyte[CONSTANT.BLOCKBYTES] block)
    {
        import inteli.emmintrin;

        __m128i[2] b, t;
        Row[4] rows;

        const(ulong)[16] m = [
            load64(block.ptr + 0 * ulong.sizeof),
            load64(block.ptr + 1 * ulong.sizeof), load64(block.ptr + 2 * ulong.sizeof),
            load64(block.ptr + 3 * ulong.sizeof), load64(block.ptr + 4 * ulong.sizeof),
            load64(block.ptr + 5 * ulong.sizeof), load64(block.ptr + 6 * ulong.sizeof),
            load64(block.ptr + 7 * ulong.sizeof), load64(block.ptr + 8 * ulong.sizeof),
            load64(block.ptr + 9 * ulong.sizeof), load64(block.ptr + 10 * ulong.sizeof),
            load64(block.ptr + 11 * ulong.sizeof), load64(block.ptr + 12 * ulong.sizeof),
            load64(block.ptr + 13 * ulong.sizeof), load64(block.ptr + 14 * ulong.sizeof),
            load64(block.ptr + 15 * ulong.sizeof)
        ];

        rows[0].l = LOADU(cast(__m128i*)(&S.h[0]));
        rows[0].h = LOADU(cast(__m128i*)(&S.h[2]));
        rows[1].l = LOADU(cast(__m128i*)(&S.h[4]));
        rows[1].h = LOADU(cast(__m128i*)(&S.h[6]));
        rows[2].l = LOADU(cast(__m128i*)(&IV[0]));
        rows[2].h = LOADU(cast(__m128i*)(&IV[2]));
        rows[3].l = _mm_xor_si128(LOADU(cast(__m128i*)(&IV[4])), LOADU(cast(__m128i*)(&S.t[0])));
        rows[3].h = _mm_xor_si128(LOADU(cast(__m128i*)(&IV[6])), LOADU(cast(__m128i*)(&S.f[0])));

        version (LDC)
        {
            mixin(tmplRound!0);
            mixin(tmplRound!1);
            mixin(tmplRound!2);
            mixin(tmplRound!3);
            mixin(tmplRound!4);
            mixin(tmplRound!5);
            mixin(tmplRound!6);
            mixin(tmplRound!7);
            mixin(tmplRound!8);
            mixin(tmplRound!9);
            mixin(tmplRound!10);
            mixin(tmplRound!11);
        }
        else
        {
            for (int i = 0; i < 12; i++)
            {
                round(m, i, rows, b, t);
            }
        }

        rows[0].l = _mm_xor_si128(rows[2].l, rows[0].l);
        rows[0].h = _mm_xor_si128(rows[2].h, rows[0].h);
        STOREU(cast(__m128i*)(&S.h[0]), _mm_xor_si128(LOADU(cast(__m128i*)(&S.h[0])), rows[0].l));
        STOREU(cast(__m128i*)(&S.h[2]), _mm_xor_si128(LOADU(cast(__m128i*)(&S.h[2])), rows[0].h));
        rows[1].l = _mm_xor_si128(rows[3].l, rows[1].l);
        rows[1].h = _mm_xor_si128(rows[3].h, rows[1].h);
        STOREU(cast(__m128i*)(&S.h[4]), _mm_xor_si128(LOADU(cast(__m128i*)(&S.h[4])), rows[1].l));
        STOREU(cast(__m128i*)(&S.h[6]), _mm_xor_si128(LOADU(cast(__m128i*)(&S.h[6])), rows[1].h));
    }


    /* init xors IV with input parameter block */
    int blake2bInitParam(State *S, const Param *P)
    {
        size_t i;
        /*blake2b_init0(S); */
        auto v = cast(const(ubyte)*)(IV);
        auto p = cast(const(ubyte)*)(P);
        auto h = cast(ubyte*)(S.h);
        /* IV XOR ParamBlock */
        memset (S, 0, state.sizeof);

        for (i = 0; i < CONSTANT.OUTBYTES; ++i) h[i] = v[i] ^ p[i];

        S.outlen = P.digestLength;
        return 0;
    }

    /* Some sort of default parameter block initialization, for sequential blake2b */
    int blake2bInit(State *S, size_t outlen)
    {
        Param P;

        assert(!(!outlen || outlen > CONSTANT.OUTBYTES), "Invalid outlen length");
        if (!outlen || outlen > CONSTANT.OUTBYTES) return -1;

        P.digestLength = cast(ubyte)outlen;
        P.keyLength    = 0;
        P.fanout       = 1;
        P.depth        = 1;
        store32(&P.leafLength, 0);
        store32(&P.nodeOffset, 0);
        store32(&P.xofLength, 0);
        P.nodeDepth    = 0;
        P.innerLength  = 0;
        memset(P.reserved.ptr, 0, P.reserved.sizeof);
        memset(P.salt.ptr,     0, P.salt.sizeof);
        memset(P.personal.ptr, 0, P.personal.sizeof);

        return blake2bInitParam(S, &P);
    }

    int blake2bInitKey(State *S, size_t outlen, const(void) *key, size_t keylen)
    {
        Param P;

        assert(!(!outlen || outlen > CONSTANT.OUTBYTES), "Invalid outlen length");
        if (!outlen || outlen > CONSTANT.OUTBYTES) return -1;
        assert(!(!keylen || keylen > CONSTANT.KEYBYTES), "Invalid keylen length");
        if (!keylen || keylen > CONSTANT.KEYBYTES) return -1;

        P.digestLength = cast(ubyte)outlen;
        P.keyLength    = cast(ubyte)keylen;
        P.fanout       = 1;
        P.depth        = 1;
        store32(&P.leafLength, 0);
        store32(&P.nodeOffset, 0);
        store32(&P.xofLength, 0);
        P.nodeDepth    = 0;
        P.innerLength  = 0;
        memset(P.reserved.ptr, 0, P.reserved.sizeof);
        memset(P.salt.ptr,     0, P.salt.sizeof);
        memset(P.personal.ptr, 0, P.personal.sizeof);

        if (blake2bInitParam(S, &P) < 0) return 0;

        ubyte[CONSTANT.BLOCKBYTES] block;
        memset(block.ptr, 0, CONSTANT.BLOCKBYTES);
        memcpy(block.ptr, key, keylen);
        blake2bUpdate(S, block.ptr, CONSTANT.BLOCKBYTES);
        secureZeroMemory(block.ptr, CONSTANT.BLOCKBYTES); /* Burn the key from stack */

        return 0;
    }

    int blake2bUpdate(State *S, const(void) *pin, size_t inlen)
    {
        auto bpin = cast(const(ubyte)*)pin;
        if (inlen > 0)
        {
            size_t left = S.buflen;
            size_t fill = CONSTANT.BLOCKBYTES - left;
            if (inlen > fill)
            {
                S.buflen = 0;
                memcpy(S.buf.ptr + left, bpin, fill); /* Fill buffer */
                incrementCounter(S, CONSTANT.BLOCKBYTES);
                compress(S, S.buf); /* Compress */
                bpin += fill;
                inlen -= fill;
                while(inlen > CONSTANT.BLOCKBYTES)
                {
                    incrementCounter(S, CONSTANT.BLOCKBYTES);
                    compress(S, bpin[0..CONSTANT.BLOCKBYTES]);
                    bpin += CONSTANT.BLOCKBYTES;
                    inlen -= CONSTANT.BLOCKBYTES;
                }
            }
            memcpy(S.buf.ptr + S.buflen, bpin, inlen);
            S.buflen += inlen;
        }
        return 0;
    }

    int blake2bFinal(State *S, void *pout, size_t outlen)
    {
        assert(!(pout == null || outlen < S.outlen), "Invalid pout or outlen length");
        if (pout == null || outlen < S.outlen) return -1;

        assert(!isLastblock(S), "Invalid block. It is the last");
        if (isLastblock(S)) return -1;

        incrementCounter(S, S.buflen);
        setLastblock(S);
        memset(S.buf.ptr + S.buflen, 0, CONSTANT.BLOCKBYTES - S.buflen); /* Padding */
        compress(S, S.buf);

        memcpy(pout, &S.h[0], S.outlen);
        return 0;
    }


    int blake2b(void *pout, size_t outlen, const(void) *pin, size_t inlen, const(void) *key, size_t keylen)
    {
        State S;

        /* Verify parameters */
        assert(!(null == pin && inlen > 0), "Invalid input");
        if (null == pin && inlen > 0) return -1;

        assert(!(null == pout), "Invalid output");
        if (null == pout) return -1;

        assert(!(null == key && keylen > 0), "Invalid key");
        if (null == key && keylen > 0) return -1;

        assert(!(!outlen || outlen > CONSTANT.OUTBYTES), "Invalid output length");
        if(!outlen || outlen > CONSTANT.OUTBYTES) return -1;

        assert(!(keylen > CONSTANT.KEYBYTES), "Invalid key length");
        if(keylen > CONSTANT.KEYBYTES) return -1;

        if (keylen)
        {
            if (blake2bInitKey(&S, outlen, key, keylen) < 0) return -1;
        }
        else
        {
            if (blake2bInit(&S, outlen) < 0) return -1;
        }

        blake2bUpdate(&S, pin, inlen);
        blake2bFinal(&S, pout, outlen);
        return 0;
    }

    int blake2b (ubyte* hash, int size, in ubyte[] input, in ubyte[] key = null)
    {
        return blake2b(hash, size, input.ptr, input.length, key.ptr, key.length);
    }
}

int blake2b (int size = B512)(out ubyte[] hash, in ubyte[] input, in ubyte[] key = null)
{
    hash = new ubyte[size];
    return blake2b(hash.ptr, size, input.ptr, input.length, key.ptr, key.length);
}


unittest
{
    import crypto.hex;
    import std.base64;
    import std.digest.crc;
    import std.stdio: writeln;

    ubyte[] hash;
    ubyte[] hashResult = hexBytes("28248967dc89fdbdaea74cb99ceec5cd4e06547f095b83d31e9a580bb739a539c077a295ef76b0ef5e8b83abe7a5f82d48639566bececfa6b80c9ec4a6a80889");
    assert(blake2b!B512(hash, cast(ubyte[])"Blake2b") == 0);
    assert(hash == hashResult);
    assert(toHexString!(LetterCase.lower)(hash) == "28248967dc89fdbdaea74cb99ceec5cd4e06547f095b83d31e9a580bb739a539c077a295ef76b0ef5e8b83abe7a5f82d48639566bececfa6b80c9ec4a6a80889");
    assert(Base64.encode(hash) == "KCSJZ9yJ/b2up0y5nO7FzU4GVH8JW4PTHppYC7c5pTnAd6KV73aw716Lg6vnpfgtSGOVZr7Oz6a4DJ7EpqgIiQ==");

    ubyte[CONSTANT.KEYBYTES] key;
    for(int i = 0; i < CONSTANT.KEYBYTES; i++)
        key[i] = cast(ubyte)i;

    // These values were taken from https://blake2.net/blake2b-test.txt
    const hashes = [
        "10ebb67700b1868efb4417987acf4690ae9d972fb7a590c2f02871799aaa4786b5e996e8f0f4eb981fc214b005f42d2ff4233499391653df7aefcbc13fc51568",
        "961f6dd1e4dd30f63901690c512e78e4b45e4742ed197c3c5e45c549fd25f2e4187b0bc9fe30492b16b0d0bc4ef9b0f34c7003fac09a5ef1532e69430234cebd",
        "da2cfbe2d8409a0f38026113884f84b50156371ae304c4430173d08a99d9fb1b983164a3770706d537f49e0c916d9f32b95cc37a95b99d857436f0232c88a965",
        "33d0825dddf7ada99b0e7e307104ad07ca9cfd9692214f1561356315e784f3e5a17e364ae9dbb14cb2036df932b77f4b292761365fb328de7afdc6d8998f5fc1",
        "beaa5a3d08f3807143cf621d95cd690514d0b49efff9c91d24b59241ec0eefa5f60196d407048bba8d2146828ebcb0488d8842fd56bb4f6df8e19c4b4daab8ac",
        "098084b51fd13deae5f4320de94a688ee07baea2800486689a8636117b46c1f4c1f6af7f74ae7c857600456a58a3af251dc4723a64cc7c0a5ab6d9cac91c20bb",
        "6044540d560853eb1c57df0077dd381094781cdb9073e5b1b3d3f6c7829e12066bbaca96d989a690de72ca3133a83652ba284a6d62942b271ffa2620c9e75b1f",
        "7a8cfe9b90f75f7ecb3acc053aaed6193112b6f6a4aeeb3f65d3de541942deb9e2228152a3c4bbbe72fc3b12629528cfbb09fe630f0474339f54abf453e2ed52",
        "380beaf6ea7cc9365e270ef0e6f3a64fb902acae51dd5512f84259ad2c91f4bc4108db73192a5bbfb0cbcf71e46c3e21aee1c5e860dc96e8eb0b7b8426e6abe9",
        "60fe3c4535e1b59d9a61ea8500bfac41a69dffb1ceadd9aca323e9a625b64da5763bad7226da02b9c8c4f1a5de140ac5a6c1124e4f718ce0b28ea47393aa6637",
        "4fe181f54ad63a2983feaaf77d1e7235c2beb17fa328b6d9505bda327df19fc37f02c4b6f0368ce23147313a8e5738b5fa2a95b29de1c7f8264eb77b69f585cd",
        "f228773ce3f3a42b5f144d63237a72d99693adb8837d0e112a8a0f8ffff2c362857ac49c11ec740d1500749dac9b1f4548108bf3155794dcc9e4082849e2b85b",
        "962452a8455cc56c8511317e3b1f3b2c37df75f588e94325fdd77070359cf63a9ae6e930936fdf8e1e08ffca440cfb72c28f06d89a2151d1c46cd5b268ef8563",
        "43d44bfa18768c59896bf7ed1765cb2d14af8c260266039099b25a603e4ddc5039d6ef3a91847d1088d401c0c7e847781a8a590d33a3c6cb4df0fab1c2f22355",
        "dcffa9d58c2a4ca2cdbb0c7aa4c4c1d45165190089f4e983bb1c2cab4aaeff1fa2b5ee516fecd780540240bf37e56c8bcca7fab980e1e61c9400d8a9a5b14ac6",
        "6fbf31b45ab0c0b8dad1c0f5f4061379912dde5aa922099a030b725c73346c524291adef89d2f6fd8dfcda6d07dad811a9314536c2915ed45da34947e83de34e",
        "a0c65bddde8adef57282b04b11e7bc8aab105b99231b750c021f4a735cb1bcfab87553bba3abb0c3e64a0b6955285185a0bd35fb8cfde557329bebb1f629ee93",
        "f99d815550558e81eca2f96718aed10d86f3f1cfb675cce06b0eff02f617c5a42c5aa760270f2679da2677c5aeb94f1142277f21c7f79f3c4f0cce4ed8ee62b1",
        "95391da8fc7b917a2044b3d6f5374e1ca072b41454d572c7356c05fd4bc1e0f40b8bb8b4a9f6bce9be2c4623c399b0dca0dab05cb7281b71a21b0ebcd9e55670",
        "04b9cd3d20d221c09ac86913d3dc63041989a9a1e694f1e639a3ba7e451840f750c2fc191d56ad61f2e7936bc0ac8e094b60caeed878c18799045402d61ceaf9",
        "ec0e0ef707e4ed6c0c66f9e089e4954b058030d2dd86398fe84059631f9ee591d9d77375355149178c0cf8f8e7c49ed2a5e4f95488a2247067c208510fadc44c",
        "9a37cce273b79c09913677510eaf7688e89b3314d3532fd2764c39de022a2945b5710d13517af8ddc0316624e73bec1ce67df15228302036f330ab0cb4d218dd",
        "4cf9bb8fb3d4de8b38b2f262d3c40f46dfe747e8fc0a414c193d9fcf753106ce47a18f172f12e8a2f1c26726545358e5ee28c9e2213a8787aafbc516d2343152",
        "64e0c63af9c808fd893137129867fd91939d53f2af04be4fa268006100069b2d69daa5c5d8ed7fddcb2a70eeecdf2b105dd46a1e3b7311728f639ab489326bc9",
        "5e9c93158d659b2def06b0c3c7565045542662d6eee8a96a89b78ade09fe8b3dcc096d4fe48815d88d8f82620156602af541955e1f6ca30dce14e254c326b88f",
        "7775dff889458dd11aef417276853e21335eb88e4dec9cfb4e9edb49820088551a2ca60339f12066101169f0dfe84b098fddb148d9da6b3d613df263889ad64b",
        "f0d2805afbb91f743951351a6d024f9353a23c7ce1fc2b051b3a8b968c233f46f50f806ecb1568ffaa0b60661e334b21dde04f8fa155ac740eeb42e20b60d764",
        "86a2af316e7d7754201b942e275364ac12ea8962ab5bd8d7fb276dc5fbffc8f9a28cae4e4867df6780d9b72524160927c855da5b6078e0b554aa91e31cb9ca1d",
        "10bdf0caa0802705e706369baf8a3f79d72c0a03a80675a7bbb00be3a45e516424d1ee88efb56f6d5777545ae6e27765c3a8f5e493fc308915638933a1dfee55",
        "b01781092b1748459e2e4ec178696627bf4ebafebba774ecf018b79a68aeb84917bf0b84bb79d17b743151144cd66b7b33a4b9e52c76c4e112050ff5385b7f0b",
        "c6dbc61dec6eaeac81e3d5f755203c8e220551534a0b2fd105a91889945a638550204f44093dd998c076205dffad703a0e5cd3c7f438a7e634cd59fededb539e",
        "eba51acffb4cea31db4b8d87e9bf7dd48fe97b0253ae67aa580f9ac4a9d941f2bea518ee286818cc9f633f2a3b9fb68e594b48cdd6d515bf1d52ba6c85a203a7",
        "86221f3ada52037b72224f105d7999231c5e5534d03da9d9c0a12acb68460cd375daf8e24386286f9668f72326dbf99ba094392437d398e95bb8161d717f8991",
        "5595e05c13a7ec4dc8f41fb70cb50a71bce17c024ff6de7af618d0cc4e9c32d9570d6d3ea45b86525491030c0d8f2b1836d5778c1ce735c17707df364d054347",
        "ce0f4f6aca89590a37fe034dd74dd5fa65eb1cbd0a41508aaddc09351a3cea6d18cb2189c54b700c009f4cbf0521c7ea01be61c5ae09cb54f27bc1b44d658c82",
        "7ee80b06a215a3bca970c77cda8761822bc103d44fa4b33f4d07dcb997e36d55298bceae12241b3fa07fa63be5576068da387b8d5859aeab701369848b176d42",
        "940a84b6a84d109aab208c024c6ce9647676ba0aaa11f86dbb7018f9fd2220a6d901a9027f9abcf935372727cbf09ebd61a2a2eeb87653e8ecad1bab85dc8327",
        "2020b78264a82d9f4151141adba8d44bf20c5ec062eee9b595a11f9e84901bf148f298e0c9f8777dcdbc7cc4670aac356cc2ad8ccb1629f16f6a76bcefbee760",
        "d1b897b0e075ba68ab572adf9d9c436663e43eb3d8e62d92fc49c9be214e6f27873fe215a65170e6bea902408a25b49506f47babd07cecf7113ec10c5dd31252",
        "b14d0c62abfa469a357177e594c10c194243ed2025ab8aa5ad2fa41ad318e0ff48cd5e60bec07b13634a711d2326e488a985f31e31153399e73088efc86a5c55",
        "4169c5cc808d2697dc2a82430dc23e3cd356dc70a94566810502b8d655b39abf9e7f902fe717e0389219859e1945df1af6ada42e4ccda55a197b7100a30c30a1",
        "258a4edb113d66c839c8b1c91f15f35ade609f11cd7f8681a4045b9fef7b0b24c82cda06a5f2067b368825e3914e53d6948ede92efd6e8387fa2e537239b5bee",
        "79d2d8696d30f30fb34657761171a11e6c3f1e64cbe7bebee159cb95bfaf812b4f411e2f26d9c421dc2c284a3342d823ec293849e42d1e46b0a4ac1e3c86abaa",
        "8b9436010dc5dee992ae38aea97f2cd63b946d94fedd2ec9671dcde3bd4ce9564d555c66c15bb2b900df72edb6b891ebcadfeff63c9ea4036a998be7973981e7",
        "c8f68e696ed28242bf997f5b3b34959508e42d613810f1e2a435c96ed2ff560c7022f361a9234b9837feee90bf47922ee0fd5f8ddf823718d86d1e16c6090071",
        "b02d3eee4860d5868b2c39ce39bfe81011290564dd678c85e8783f29302dfc1399ba95b6b53cd9ebbf400cca1db0ab67e19a325f2d115812d25d00978ad1bca4",
        "7693ea73af3ac4dad21ca0d8da85b3118a7d1c6024cfaf557699868217bc0c2f44a199bc6c0edd519798ba05bd5b1b4484346a47c2cadf6bf30b785cc88b2baf",
        "a0e5c1c0031c02e48b7f09a5e896ee9aef2f17fc9e18e997d7f6cac7ae316422c2b1e77984e5f3a73cb45deed5d3f84600105e6ee38f2d090c7d0442ea34c46d",
        "41daa6adcfdb69f1440c37b596440165c15ada596813e2e22f060fcd551f24dee8e04ba6890387886ceec4a7a0d7fc6b44506392ec3822c0d8c1acfc7d5aebe8",
        "14d4d40d5984d84c5cf7523b7798b254e275a3a8cc0a1bd06ebc0bee726856acc3cbf516ff667cda2058ad5c3412254460a82c92187041363cc77a4dc215e487",
        "d0e7a1e2b9a447fee83e2277e9ff8010c2f375ae12fa7aaa8ca5a6317868a26a367a0b69fbc1cf32a55d34eb370663016f3d2110230eba754028a56f54acf57c",
        "e771aa8db5a3e043e8178f39a0857ba04a3f18e4aa05743cf8d222b0b095825350ba422f63382a23d92e4149074e816a36c1cd28284d146267940b31f8818ea2",
        "feb4fd6f9e87a56bef398b3284d2bda5b5b0e166583a66b61e538457ff0584872c21a32962b9928ffab58de4af2edd4e15d8b35570523207ff4e2a5aa7754caa",
        "462f17bf005fb1c1b9e671779f665209ec2873e3e411f98dabf240a1d5ec3f95ce6796b6fc23fe171903b502023467dec7273ff74879b92967a2a43a5a183d33",
        "d3338193b64553dbd38d144bea71c5915bb110e2d88180dbc5db364fd6171df317fc7268831b5aef75e4342b2fad8797ba39eddcef80e6ec08159350b1ad696d",
        "e1590d585a3d39f7cb599abd479070966409a6846d4377acf4471d065d5db94129cc9be92573b05ed226be1e9b7cb0cabe87918589f80dadd4ef5ef25a93d28e",
        "f8f3726ac5a26cc80132493a6fedcb0e60760c09cfc84cad178175986819665e76842d7b9fedf76dddebf5d3f56faaad4477587af21606d396ae570d8e719af2",
        "30186055c07949948183c850e9a756cc09937e247d9d928e869e20bafc3cd9721719d34e04a0899b92c736084550186886efba2e790d8be6ebf040b209c439a4",
        "f3c4276cb863637712c241c444c5cc1e3554e0fddb174d035819dd83eb700b4ce88df3ab3841ba02085e1a99b4e17310c5341075c0458ba376c95a6818fbb3e2",
        "0aa007c4dd9d5832393040a1583c930bca7dc5e77ea53add7e2b3f7c8e231368043520d4a3ef53c969b6bbfd025946f632bd7f765d53c21003b8f983f75e2a6a",
        "08e9464720533b23a04ec24f7ae8c103145f765387d738777d3d343477fd1c58db052142cab754ea674378e18766c53542f71970171cc4f81694246b717d7564",
        "d37ff7ad297993e7ec21e0f1b4b5ae719cdc83c5db687527f27516cbffa822888a6810ee5c1ca7bfe3321119be1ab7bfa0a502671c8329494df7ad6f522d440f",
        "dd9042f6e464dcf86b1262f6accfafbd8cfd902ed3ed89abf78ffa482dbdeeb6969842394c9a1168ae3d481a017842f660002d42447c6b22f7b72f21aae021c9",
        "bd965bf31e87d70327536f2a341cebc4768eca275fa05ef98f7f1b71a0351298de006fba73fe6733ed01d75801b4a928e54231b38e38c562b2e33ea1284992fa",
        "65676d800617972fbd87e4b9514e1c67402b7a331096d3bfac22f1abb95374abc942f16e9ab0ead33b87c91968a6e509e119ff07787b3ef483e1dcdccf6e3022",
        "939fa189699c5d2c81ddd1ffc1fa207c970b6a3685bb29ce1d3e99d42f2f7442da53e95a72907314f4588399a3ff5b0a92beb3f6be2694f9f86ecf2952d5b41c",
        "c516541701863f91005f314108ceece3c643e04fc8c42fd2ff556220e616aaa6a48aeb97a84bad74782e8dff96a1a2fa949339d722edcaa32b57067041df88cc",
        "987fd6e0d6857c553eaebb3d34970a2c2f6e89a3548f492521722b80a1c21a153892346d2cba6444212d56da9a26e324dccbc0dcde85d4d2ee4399eec5a64e8f",
        "ae56deb1c2328d9c4017706bce6e99d41349053ba9d336d677c4c27d9fd50ae6aee17e853154e1f4fe7672346da2eaa31eea53fcf24a22804f11d03da6abfc2b",
        "49d6a608c9bde4491870498572ac31aac3fa40938b38a7818f72383eb040ad39532bc06571e13d767e6945ab77c0bdc3b0284253343f9f6c1244ebf2ff0df866",
        "da582ad8c5370b4469af862aa6467a2293b2b28bd80ae0e91f425ad3d47249fdf98825cc86f14028c3308c9804c78bfeeeee461444ce243687e1a50522456a1d",
        "d5266aa3331194aef852eed86d7b5b2633a0af1c735906f2e13279f14931a9fc3b0eac5ce9245273bd1aa92905abe16278ef7efd47694789a7283b77da3c70f8",
        "2962734c28252186a9a1111c732ad4de4506d4b4480916303eb7991d659ccda07a9911914bc75c418ab7a4541757ad054796e26797feaf36e9f6ad43f14b35a4",
        "e8b79ec5d06e111bdfafd71e9f5760f00ac8ac5d8bf768f9ff6f08b8f026096b1cc3a4c973333019f1e3553e77da3f98cb9f542e0a90e5f8a940cc58e59844b3",
        "dfb320c44f9d41d1efdcc015f08dd5539e526e39c87d509ae6812a969e5431bf4fa7d91ffd03b981e0d544cf72d7b1c0374f8801482e6dea2ef903877eba675e",
        "d88675118fdb55a5fb365ac2af1d217bf526ce1ee9c94b2f0090b2c58a06ca58187d7fe57c7bed9d26fca067b4110eefcd9a0a345de872abe20de368001b0745",
        "b893f2fc41f7b0dd6e2f6aa2e0370c0cff7df09e3acfcc0e920b6e6fad0ef747c40668417d342b80d2351e8c175f20897a062e9765e6c67b539b6ba8b9170545",
        "6c67ec5697accd235c59b486d7b70baeedcbd4aa64ebd4eef3c7eac189561a726250aec4d48cadcafbbe2ce3c16ce2d691a8cce06e8879556d4483ed7165c063",
        "f1aa2b044f8f0c638a3f362e677b5d891d6fd2ab0765f6ee1e4987de057ead357883d9b405b9d609eea1b869d97fb16d9b51017c553f3b93c0a1e0f1296fedcd",
        "cbaa259572d4aebfc1917acddc582b9f8dfaa928a198ca7acd0f2aa76a134a90252e6298a65b08186a350d5b7626699f8cb721a3ea5921b753ae3a2dce24ba3a",
        "fa1549c9796cd4d303dcf452c1fbd5744fd9b9b47003d920b92de34839d07ef2a29ded68f6fc9e6c45e071a2e48bd50c5084e96b657dd0404045a1ddefe282ed",
        "5cf2ac897ab444dcb5c8d87c495dbdb34e1838b6b629427caa51702ad0f9688525f13bec503a3c3a2c80a65e0b5715e8afab00ffa56ec455a49a1ad30aa24fcd",
        "9aaf80207bace17bb7ab145757d5696bde32406ef22b44292ef65d4519c3bb2ad41a59b62cc3e94b6fa96d32a7faadae28af7d35097219aa3fd8cda31e40c275",
        "af88b163402c86745cb650c2988fb95211b94b03ef290eed9662034241fd51cf398f8073e369354c43eae1052f9b63b08191caa138aa54fea889cc7024236897",
        "48fa7d64e1ceee27b9864db5ada4b53d00c9bc7626555813d3cd6730ab3cc06ff342d727905e33171bde6e8476e77fb1720861e94b73a2c538d254746285f430",
        "0e6fd97a85e904f87bfe85bbeb34f69e1f18105cf4ed4f87aec36c6e8b5f68bd2a6f3dc8a9ecb2b61db4eedb6b2ea10bf9cb0251fb0f8b344abf7f366b6de5ab",
        "06622da5787176287fdc8fed440bad187d830099c94e6d04c8e9c954cda70c8bb9e1fc4a6d0baa831b9b78ef6648681a4867a11da93ee36e5e6a37d87fc63f6f",
        "1da6772b58fabf9c61f68d412c82f182c0236d7d575ef0b58dd22458d643cd1dfc93b03871c316d8430d312995d4197f0874c99172ba004a01ee295abac24e46",
        "3cd2d9320b7b1d5fb9aab951a76023fa667be14a9124e394513918a3f44096ae4904ba0ffc150b63bc7ab1eeb9a6e257e5c8f000a70394a5afd842715de15f29",
        "04cdc14f7434e0b4be70cb41db4c779a88eaef6accebcb41f2d42fffe7f32a8e281b5c103a27021d0d08362250753cdf70292195a53a48728ceb5844c2d98bab",
        "9071b7a8a075d0095b8fb3ae5113785735ab98e2b52faf91d5b89e44aac5b5d4ebbf91223b0ff4c71905da55342e64655d6ef8c89a4768c3f93a6dc0366b5bc8",
        "ebb30240dd96c7bc8d0abe49aa4edcbb4afdc51ff9aaf720d3f9e7fbb0f9c6d6571350501769fc4ebd0b2141247ff400d4fd4be414edf37757bb90a32ac5c65a",
        "8532c58bf3c8015d9d1cbe00eef1f5082f8f3632fbe9f1ed4f9dfb1fa79e8283066d77c44c4af943d76b300364aecbd0648c8a8939bd204123f4b56260422dec",
        "fe9846d64f7c7708696f840e2d76cb4408b6595c2f81ec6a28a7f2f20cb88cfe6ac0b9e9b8244f08bd7095c350c1d0842f64fb01bb7f532dfcd47371b0aeeb79",
        "28f17ea6fb6c42092dc264257e29746321fb5bdaea9873c2a7fa9d8f53818e899e161bc77dfe8090afd82bf2266c5c1bc930a8d1547624439e662ef695f26f24",
        "ec6b7d7f030d4850acae3cb615c21dd25206d63e84d1db8d957370737ba0e98467ea0ce274c66199901eaec18a08525715f53bfdb0aacb613d342ebdceeddc3b",
        "b403d3691c03b0d3418df327d5860d34bbfcc4519bfbce36bf33b208385fadb9186bc78a76c489d89fd57e7dc75412d23bcd1dae8470ce9274754bb8585b13c5",
        "31fc79738b8772b3f55cd8178813b3b52d0db5a419d30ba9495c4b9da0219fac6df8e7c23a811551a62b827f256ecdb8124ac8a6792ccfecc3b3012722e94463",
        "bb2039ec287091bcc9642fc90049e73732e02e577e2862b32216ae9bedcd730c4c284ef3968c368b7d37584f97bd4b4dc6ef6127acfe2e6ae2509124e66c8af4",
        "f53d68d13f45edfcb9bd415e2831e938350d5380d3432278fc1c0c381fcb7c65c82dafe051d8c8b0d44e0974a0e59ec7bf7ed0459f86e96f329fc79752510fd3",
        "8d568c7984f0ecdf7640fbc483b5d8c9f86634f6f43291841b309a350ab9c1137d24066b09da9944bac54d5bb6580d836047aac74ab724b887ebf93d4b32eca9",
        "c0b65ce5a96ff774c456cac3b5f2c4cd359b4ff53ef93a3da0778be4900d1e8da1601e769e8f1b02d2a2f8c5b9fa10b44f1c186985468feeb008730283a6657d",
        "4900bba6f5fb103ece8ec96ada13a5c3c85488e05551da6b6b33d988e611ec0fe2e3c2aa48ea6ae8986a3a231b223c5d27cec2eadde91ce07981ee652862d1e4",
        "c7f5c37c7285f927f76443414d4357ff789647d7a005a5a787e03c346b57f49f21b64fa9cf4b7e45573e23049017567121a9c3d4b2b73ec5e9413577525db45a",
        "ec7096330736fdb2d64b5653e7475da746c23a4613a82687a28062d3236364284ac01720ffb406cfe265c0df626a188c9e5963ace5d3d5bb363e32c38c2190a6",
        "82e744c75f4649ec52b80771a77d475a3bc091989556960e276a5f9ead92a03f718742cdcfeaee5cb85c44af198adc43a4a428f5f0c2ddb0be36059f06d7df73",
        "2834b7a7170f1f5b68559ab78c1050ec21c919740b784a9072f6e5d69f828d70c919c5039fb148e39e2c8a52118378b064ca8d5001cd10a5478387b966715ed6",
        "16b4ada883f72f853bb7ef253efcab0c3e2161687ad61543a0d2824f91c1f81347d86be709b16996e17f2dd486927b0288ad38d13063c4a9672c39397d3789b6",
        "78d048f3a69d8b54ae0ed63a573ae350d89f7c6cf1f3688930de899afa037697629b314e5cd303aa62feea72a25bf42b304b6c6bcb27fae21c16d925e1fbdac3",
        "0f746a48749287ada77a82961f05a4da4abdb7d77b1220f836d09ec814359c0ec0239b8c7b9ff9e02f569d1b301ef67c4612d1de4f730f81c12c40cc063c5caa",
        "f0fc859d3bd195fbdc2d591e4cdac15179ec0f1dc821c11df1f0c1d26e6260aaa65b79fafacafd7d3ad61e600f250905f5878c87452897647a35b995bcadc3a3",
        "2620f687e8625f6a412460b42e2cef67634208ce10a0cbd4dff7044a41b7880077e9f8dc3b8d1216d3376a21e015b58fb279b521d83f9388c7382c8505590b9b",
        "227e3aed8d2cb10b918fcb04f9de3e6d0a57e08476d93759cd7b2ed54a1cbf0239c528fb04bbf288253e601d3bc38b21794afef90b17094a182cac557745e75f",
        "1a929901b09c25f27d6b35be7b2f1c4745131fdebca7f3e2451926720434e0db6e74fd693ad29b777dc3355c592a361c4873b01133a57c2e3b7075cbdb86f4fc",
        "5fd7968bc2fe34f220b5e3dc5af9571742d73b7d60819f2888b629072b96a9d8ab2d91b82d0a9aaba61bbd39958132fcc4257023d1eca591b3054e2dc81c8200",
        "dfcce8cf32870cc6a503eadafc87fd6f78918b9b4d0737db6810be996b5497e7e5cc80e312f61e71ff3e9624436073156403f735f56b0b01845c18f6caf772e6",
        "02f7ef3a9ce0fff960f67032b296efca3061f4934d690749f2d01c35c81c14f39a67fa350bc8a0359bf1724bffc3bca6d7c7bba4791fd522a3ad353c02ec5aa8",
        "64be5c6aba65d594844ae78bb022e5bebe127fd6b6ffa5a13703855ab63b624dcd1a363f99203f632ec386f3ea767fc992e8ed9686586aa27555a8599d5b808f",
        "f78585505c4eaa54a8b5be70a61e735e0ff97af944ddb3001e35d86c4e2199d976104b6ae31750a36a726ed285064f5981b503889fef822fcdc2898dddb7889a",
        "e4b5566033869572edfd87479a5bb73c80e8759b91232879d96b1dda36c012076ee5a2ed7ae2de63ef8406a06aea82c188031b560beafb583fb3de9e57952a7e",
        "e1b3e7ed867f6c9484a2a97f7715f25e25294e992e41f6a7c161ffc2adc6daaeb7113102d5e6090287fe6ad94ce5d6b739c6ca240b05c76fb73f25dd024bf935",
        "85fd085fdc12a080983df07bd7012b0d402a0f4043fcb2775adf0bad174f9b08d1676e476985785c0a5dcc41dbff6d95ef4d66a3fbdc4a74b82ba52da0512b74",
        "aed8fa764b0fbff821e05233d2f7b0900ec44d826f95e93c343c1bc3ba5a24374b1d616e7e7aba453a0ada5e4fab5382409e0d42ce9c2bc7fb39a99c340c20f0",
        "7ba3b2e297233522eeb343bd3ebcfd835a04007735e87f0ca300cbee6d416565162171581e4020ff4cf176450f1291ea2285cb9ebffe4c56660627685145051c",
        "de748bcf89ec88084721e16b85f30adb1a6134d664b5843569babc5bbd1a15ca9b61803c901a4fef32965a1749c9f3a4e243e173939dc5a8dc495c671ab52145",
        "aaf4d2bdf200a919706d9842dce16c98140d34bc433df320aba9bd429e549aa7a3397652a4d768277786cf993cde2338673ed2e6b66c961fefb82cd20c93338f",
        "c408218968b788bf864f0997e6bc4c3dba68b276e2125a4843296052ff93bf5767b8cdce7131f0876430c1165fec6c4f47adaa4fd8bcfacef463b5d3d0fa61a0",
        "76d2d819c92bce55fa8e092ab1bf9b9eab237a25267986cacf2b8ee14d214d730dc9a5aa2d7b596e86a1fd8fa0804c77402d2fcd45083688b218b1cdfa0dcbcb",
        "72065ee4dd91c2d8509fa1fc28a37c7fc9fa7d5b3f8ad3d0d7a25626b57b1b44788d4caf806290425f9890a3a2a35a905ab4b37acfd0da6e4517b2525c9651e4",
        "64475dfe7600d7171bea0b394e27c9b00d8e74dd1e416a79473682ad3dfdbb706631558055cfc8a40e07bd015a4540dcdea15883cbbf31412df1de1cd4152b91",
        "12cd1674a4488a5d7c2b3160d2e2c4b58371bedad793418d6f19c6ee385d70b3e06739369d4df910edb0b0a54cbff43d54544cd37ab3a06cfa0a3ddac8b66c89",
        "60756966479dedc6dd4bcff8ea7d1d4ce4d4af2e7b097e32e3763518441147cc12b3c0ee6d2ecabf1198cec92e86a3616fba4f4e872f5825330adbb4c1dee444",
        "a7803bcb71bc1d0f4383dde1e0612e04f872b715ad30815c2249cf34abb8b024915cb2fc9f4e7cc4c8cfd45be2d5a91eab0941c7d270e2da4ca4a9f7ac68663a",
        "b84ef6a7229a34a750d9a98ee2529871816b87fbe3bc45b45fa5ae82d5141540211165c3c5d7a7476ba5a4aa06d66476f0d9dc49a3f1ee72c3acabd498967414",
        "fae4b6d8efc3f8c8e64d001dabec3a21f544e82714745251b2b4b393f2f43e0da3d403c64db95a2cb6e23ebb7b9e94cdd5ddac54f07c4a61bd3cb10aa6f93b49",
        "34f7286605a122369540141ded79b8957255da2d4155abbf5a8dbb89c8eb7ede8eeef1daa46dc29d751d045dc3b1d658bb64b80ff8589eddb3824b13da235a6b",
        "3b3b48434be27b9eababba43bf6b35f14b30f6a88dc2e750c358470d6b3aa3c18e47db4017fa55106d8252f016371a00f5f8b070b74ba5f23cffc5511c9f09f0",
        "ba289ebd6562c48c3e10a8ad6ce02e73433d1e93d7c9279d4d60a7e879ee11f441a000f48ed9f7c4ed87a45136d7dccdca482109c78a51062b3ba4044ada2469",
        "022939e2386c5a37049856c850a2bb10a13dfea4212b4c732a8840a9ffa5faf54875c5448816b2785a007da8a8d2bc7d71a54e4e6571f10b600cbdb25d13ede3",
        "e6fec19d89ce8717b1a087024670fe026f6c7cbda11caef959bb2d351bf856f8055d1c0ebdaaa9d1b17886fc2c562b5e99642fc064710c0d3488a02b5ed7f6fd",
        "94c96f02a8f576aca32ba61c2b206f907285d9299b83ac175c209a8d43d53bfe683dd1d83e7549cb906c28f59ab7c46f8751366a28c39dd5fe2693c9019666c8",
        "31a0cd215ebd2cb61de5b9edc91e6195e31c59a5648d5c9f737e125b2605708f2e325ab3381c8dce1a3e958886f1ecdc60318f882cfe20a24191352e617b0f21",
        "91ab504a522dce78779f4c6c6ba2e6b6db5565c76d3e7e7c920caf7f757ef9db7c8fcf10e57f03379ea9bf75eb59895d96e149800b6aae01db778bb90afbc989",
        "d85cabc6bd5b1a01a5afd8c6734740da9fd1c1acc6db29bfc8a2e5b668b028b6b3154bfb8703fa3180251d589ad38040ceb707c4bad1b5343cb426b61eaa49c1",
        "d62efbec2ca9c1f8bd66ce8b3f6a898cb3f7566ba6568c618ad1feb2b65b76c3ce1dd20f7395372faf28427f61c9278049cf0140df434f5633048c86b81e0399",
        "7c8fdc6175439e2c3db15bafa7fb06143a6a23bc90f449e79deef73c3d492a671715c193b6fea9f036050b946069856b897e08c00768f5ee5ddcf70b7cd6d0e0",
        "58602ee7468e6bc9df21bd51b23c005f72d6cb013f0a1b48cbec5eca299299f97f09f54a9a01483eaeb315a6478bad37ba47ca1347c7c8fc9e6695592c91d723",
        "27f5b79ed256b050993d793496edf4807c1d85a7b0a67c9c4fa99860750b0ae66989670a8ffd7856d7ce411599e58c4d77b232a62bef64d15275be46a68235ff",
        "3957a976b9f1887bf004a8dca942c92d2b37ea52600f25e0c9bc5707d0279c00c6e85a839b0d2d8eb59c51d94788ebe62474a791cadf52cccf20f5070b6573fc",
        "eaa2376d55380bf772ecca9cb0aa4668c95c707162fa86d518c8ce0ca9bf7362b9f2a0adc3ff59922df921b94567e81e452f6c1a07fc817cebe99604b3505d38",
        "c1e2c78b6b2734e2480ec550434cb5d613111adcc21d475545c3b1b7e6ff12444476e5c055132e2229dc0f807044bb919b1a5662dd38a9ee65e243a3911aed1a",
        "8ab48713389dd0fcf9f965d3ce66b1e559a1f8c58741d67683cd971354f452e62d0207a65e436c5d5d8f8ee71c6abfe50e669004c302b31a7ea8311d4a916051",
        "24ce0addaa4c65038bd1b1c0f1452a0b128777aabc94a29df2fd6c7e2f85f8ab9ac7eff516b0e0a825c84a24cfe492eaad0a6308e46dd42fe8333ab971bb30ca",
        "5154f929ee03045b6b0c0004fa778edee1d139893267cc84825ad7b36c63de32798e4a166d24686561354f63b00709a1364b3c241de3febf0754045897467cd4",
        "e74e907920fd87bd5ad636dd11085e50ee70459c443e1ce5809af2bc2eba39f9e6d7128e0e3712c316da06f4705d78a4838e28121d4344a2c79c5e0db307a677",
        "bf91a22334bac20f3fd80663b3cd06c4e8802f30e6b59f90d3035cc9798a217ed5a31abbda7fa6842827bdf2a7a1c21f6fcfccbb54c6c52926f32da816269be1",
        "d9d5c74be5121b0bd742f26bffb8c89f89171f3f934913492b0903c271bbe2b3395ef259669bef43b57f7fcc3027db01823f6baee66e4f9fead4d6726c741fce",
        "50c8b8cf34cd879f80e2faab3230b0c0e1cc3e9dcadeb1b9d97ab923415dd9a1fe38addd5c11756c67990b256e95ad6d8f9fedce10bf1c90679cde0ecf1be347",
        "0a386e7cd5dd9b77a035e09fe6fee2c8ce61b5383c87ea43205059c5e4cd4f4408319bb0a82360f6a58e6c9ce3f487c446063bf813bc6ba535e17fc1826cfc91",
        "1f1459cb6b61cbac5f0efe8fc487538f42548987fcd56221cfa7beb22504769e792c45adfb1d6b3d60d7b749c8a75b0bdf14e8ea721b95dca538ca6e25711209",
        "e58b3836b7d8fedbb50ca5725c6571e74c0785e97821dab8b6298c10e4c079d4a6cdf22f0fedb55032925c16748115f01a105e77e00cee3d07924dc0d8f90659",
        "b929cc6505f020158672deda56d0db081a2ee34c00c1100029bdf8ea98034fa4bf3e8655ec697fe36f40553c5bb46801644a627d3342f4fc92b61f03290fb381",
        "72d353994b49d3e03153929a1e4d4f188ee58ab9e72ee8e512f29bc773913819ce057ddd7002c0433ee0a16114e3d156dd2c4a7e80ee53378b8670f23e33ef56",
        "c70ef9bfd775d408176737a0736d68517ce1aaad7e81a93c8c1ed967ea214f56c8a377b1763e676615b60f3988241eae6eab9685a5124929d28188f29eab06f7",
        "c230f0802679cb33822ef8b3b21bf7a9a28942092901d7dac3760300831026cf354c9232df3e084d9903130c601f63c1f4a4a4b8106e468cd443bbe5a734f45f",
        "6f43094cafb5ebf1f7a4937ec50f56a4c9da303cbb55ac1f27f1f1976cd96beda9464f0e7b9c54620b8a9fba983164b8be3578425a024f5fe199c36356b88972",
        "3745273f4c38225db2337381871a0c6aafd3af9b018c88aa02025850a5dc3a42a1a3e03e56cbf1b0876d63a441f1d2856a39b8801eb5af325201c415d65e97fe",
        "c50c44cca3ec3edaae779a7e179450ebdda2f97067c690aa6c5a4ac7c30139bb27c0df4db3220e63cb110d64f37ffe078db72653e2daacf93ae3f0a2d1a7eb2e",
        "8aef263e385cbc61e19b28914243262af5afe8726af3ce39a79c27028cf3ecd3f8d2dfd9cfc9ad91b58f6f20778fd5f02894a3d91c7d57d1e4b866a7f364b6be",
        "28696141de6e2d9bcb3235578a66166c1448d3e905a1b482d423be4bc5369bc8c74dae0acc9cc123e1d8ddce9f97917e8c019c552da32d39d2219b9abf0fa8c8",
        "2fb9eb2085830181903a9dafe3db428ee15be7662224efd643371fb25646aee716e531eca69b2bdc8233f1a8081fa43da1500302975a77f42fa592136710e9dc",
        "66f9a7143f7a3314a669bf2e24bbb35014261d639f495b6c9c1f104fe8e320aca60d4550d69d52edbd5a3cdeb4014ae65b1d87aa770b69ae5c15f4330b0b0ad8",
        "f4c4dd1d594c3565e3e25ca43dad82f62abea4835ed4cd811bcd975e46279828d44d4c62c3679f1b7f7b9dd4571d7b49557347b8c5460cbdc1bef690fb2a08c0",
        "8f1dc9649c3a84551f8f6e91cac68242a43b1f8f328ee92280257387fa7559aa6db12e4aeadc2d26099178749c6864b357f3f83b2fb3efa8d2a8db056bed6bcc",
        "3139c1a7f97afd1675d460ebbc07f2728aa150df849624511ee04b743ba0a833092f18c12dc91b4dd243f333402f59fe28abdbbbae301e7b659c7a26d5c0f979",
        "06f94a2996158a819fe34c40de3cf0379fd9fb85b3e363ba3926a0e7d960e3f4c2e0c70c7ce0ccb2a64fc29869f6e7ab12bd4d3f14fce943279027e785fb5c29",
        "c29c399ef3eee8961e87565c1ce263925fc3d0ce267d13e48dd9e732ee67b0f69fad56401b0f10fcaac119201046cca28c5b14abdea3212ae65562f7f138db3d",
        "4cec4c9df52eef05c3f6faaa9791bc7445937183224ecc37a1e58d0132d35617531d7e795f52af7b1eb9d147de1292d345fe341823f8e6bc1e5badca5c656108",
        "898bfbae93b3e18d00697eab7d9704fa36ec339d076131cefdf30edbe8d9cc81c3a80b129659b163a323bab9793d4feed92d54dae966c77529764a09be88db45",
        "ee9bd0469d3aaf4f14035be48a2c3b84d9b4b1fff1d945e1f1c1d38980a951be197b25fe22c731f20aeacc930ba9c4a1f4762227617ad350fdabb4e80273a0f4",
        "3d4d3113300581cd96acbf091c3d0f3c310138cd6979e6026cde623e2dd1b24d4a8638bed1073344783ad0649cc6305ccec04beb49f31c633088a99b65130267",
        "95c0591ad91f921ac7be6d9ce37e0663ed8011c1cfd6d0162a5572e94368bac02024485e6a39854aa46fe38e97d6c6b1947cd272d86b06bb5b2f78b9b68d559d",
        "227b79ded368153bf46c0a3ca978bfdbef31f3024a5665842468490b0ff748ae04e7832ed4c9f49de9b1706709d623e5c8c15e3caecae8d5e433430ff72f20eb",
        "5d34f3952f0105eef88ae8b64c6ce95ebfade0e02c69b08762a8712d2e4911ad3f941fc4034dc9b2e479fdbcd279b902faf5d838bb2e0c6495d372b5b7029813",
        "7f939bf8353abce49e77f14f3750af20b7b03902e1a1e7fb6aaf76d0259cd401a83190f15640e74f3e6c5a90e839c7821f6474757f75c7bf9002084ddc7a62dc",
        "062b61a2f9a33a71d7d0a06119644c70b0716a504de7e5e1be49bd7b86e7ed6817714f9f0fc313d06129597e9a2235ec8521de36f7290a90ccfc1ffa6d0aee29",
        "f29e01eeae64311eb7f1c6422f946bf7bea36379523e7b2bbaba7d1d34a22d5ea5f1c5a09d5ce1fe682cced9a4798d1a05b46cd72dff5c1b355440b2a2d476bc",
        "ec38cd3bbab3ef35d7cb6d5c914298351d8a9dc97fcee051a8a02f58e3ed6184d0b7810a5615411ab1b95209c3c810114fdeb22452084e77f3f847c6dbaafe16",
        "c2aef5e0ca43e82641565b8cb943aa8ba53550caef793b6532fafad94b816082f0113a3ea2f63608ab40437ecc0f0229cb8fa224dcf1c478a67d9b64162b92d1",
        "15f534efff7105cd1c254d074e27d5898b89313b7d366dc2d7d87113fa7d53aae13f6dba487ad8103d5e854c91fdb6e1e74b2ef6d1431769c30767dde067a35c",
        "89acbca0b169897a0a2714c2df8c95b5b79cb69390142b7d6018bb3e3076b099b79a964152a9d912b1b86412b7e372e9cecad7f25d4cbab8a317be36492a67d7",
        "e3c0739190ed849c9c962fd9dbb55e207e624fcac1eb417691515499eea8d8267b7e8f1287a63633af5011fde8c4ddf55bfdf722edf88831414f2cfaed59cb9a",
        "8d6cf87c08380d2d1506eee46fd4222d21d8c04e585fbfd08269c98f702833a156326a0724656400ee09351d57b440175e2a5de93cc5f80db6daf83576cf75fa",
        "da24bede383666d563eeed37f6319baf20d5c75d1635a6ba5ef4cfa1ac95487e96f8c08af600aab87c986ebad49fc70a58b4890b9c876e091016daf49e1d322e",
        "f9d1d1b1e87ea7ae753a029750cc1cf3d0157d41805e245c5617bb934e732f0ae3180b78e05bfe76c7c3051e3e3ac78b9b50c05142657e1e03215d6ec7bfd0fc",
        "11b7bc1668032048aa43343de476395e814bbbc223678db951a1b03a021efac948cfbe215f97fe9a72a2f6bc039e3956bfa417c1a9f10d6d7ba5d3d32ff323e5",
        "b8d9000e4fc2b066edb91afee8e7eb0f24e3a201db8b6793c0608581e628ed0bcc4e5aa6787992a4bcc44e288093e63ee83abd0bc3ec6d0934a674a4da13838a",
        "ce325e294f9b6719d6b61278276ae06a2564c03bb0b783fafe785bdf89c7d5acd83e78756d301b445699024eaeb77b54d477336ec2a4f332f2b3f88765ddb0c3",
        "29acc30e9603ae2fccf90bf97e6cc463ebe28c1b2f9b4b765e70537c25c702a29dcbfbf14c99c54345ba2b51f17b77b5f15db92bbad8fa95c471f5d070a137cc",
        "3379cbaae562a87b4c0425550ffdd6bfe1203f0d666cc7ea095be407a5dfe61ee91441cd5154b3e53b4f5fb31ad4c7a9ad5c7af4ae679aa51a54003a54ca6b2d",
        "3095a349d245708c7cf550118703d7302c27b60af5d4e67fc978f8a4e60953c7a04f92fcf41aee64321ccb707a895851552b1e37b00bc5e6b72fa5bcef9e3fff",
        "07262d738b09321f4dbccec4bb26f48cb0f0ed246ce0b31b9a6e7bc683049f1f3e5545f28ce932dd985c5ab0f43bd6de0770560af329065ed2e49d34624c2cbb",
        "b6405eca8ee3316c87061cc6ec18dba53e6c250c63ba1f3bae9e55dd3498036af08cd272aa24d713c6020d77ab2f3919af1a32f307420618ab97e73953994fb4",
        "7ee682f63148ee45f6e5315da81e5c6e557c2c34641fc509c7a5701088c38a74756168e2cd8d351e88fd1a451f360a01f5b2580f9b5a2e8cfc138f3dd59a3ffc",
        "1d263c179d6b268f6fa016f3a4f29e943891125ed8593c81256059f5a7b44af2dcb2030d175c00e62ecaf7ee96682aa07ab20a611024a28532b1c25b86657902",
        "106d132cbdb4cd2597812846e2bc1bf732fec5f0a5f65dbb39ec4e6dc64ab2ce6d24630d0f15a805c3540025d84afa98e36703c3dbee713e72dde8465bc1be7e",
        "0e79968226650667a8d862ea8da4891af56a4e3a8b6d1750e394f0dea76d640d85077bcec2cc86886e506751b4f6a5838f7f0b5fef765d9dc90dcdcbaf079f08",
        "521156a82ab0c4e566e5844d5e31ad9aaf144bbd5a464fdca34dbd5717e8ff711d3ffebbfa085d67fe996a34f6d3e4e60b1396bf4b1610c263bdbb834d560816",
        "1aba88befc55bc25efbce02db8b9933e46f57661baeabeb21cc2574d2a518a3cba5dc5a38e49713440b25f9c744e75f6b85c9d8f4681f676160f6105357b8406",
        "5a9949fcb2c473cda968ac1b5d08566dc2d816d960f57e63b898fa701cf8ebd3f59b124d95bfbbedc5f1cf0e17d5eaed0c02c50b69d8a402cabcca4433b51fd4",
        "b0cead09807c672af2eb2b0f06dde46cf5370e15a4096b1a7d7cbb36ec31c205fbefca00b7a4162fa89fb4fb3eb78d79770c23f44e7206664ce3cd931c291e5d",
        "bb6664931ec97044e45b2ae420ae1c551a8874bc937d08e969399c3964ebdba8346cdd5d09caafe4c28ba7ec788191ceca65ddd6f95f18583e040d0f30d0364d",
        "65bc770a5faa3792369803683e844b0be7ee96f29f6d6a35568006bd5590f9a4ef639b7a8061c7b0424b66b60ac34af3119905f33a9d8c3ae18382ca9b689900",
        "ea9b4dca333336aaf839a45c6eaa48b8cb4c7ddabffea4f643d6357ea6628a480a5b45f2b052c1b07d1fedca918b6f1139d80f74c24510dcbaa4be70eacc1b06",
        "e6342fb4a780ad975d0e24bce149989b91d360557e87994f6b457b895575cc02d0c15bad3ce7577f4c63927ff13f3e381ff7e72bdbe745324844a9d27e3f1c01",
        "3e209c9b33e8e461178ab46b1c64b49a07fb745f1c8bc95fbfb94c6b87c69516651b264ef980937fad41238b91ddc011a5dd777c7efd4494b4b6ecd3a9c22ac0",
        "fd6a3d5b1875d80486d6e69694a56dbb04a99a4d051f15db2689776ba1c4882e6d462a603b7015dc9f4b7450f05394303b8652cfb404a266962c41bae6e18a94",
        "951e27517e6bad9e4195fc8671dee3e7e9be69cee1422cb9fecfce0dba875f7b310b93ee3a3d558f941f635f668ff832d2c1d033c5e2f0997e4c66f147344e02",
        "8eba2f874f1ae84041903c7c4253c82292530fc8509550bfdc34c95c7e2889d5650b0ad8cb988e5c4894cb87fbfbb19612ea93ccc4c5cad17158b9763464b492",
        "16f712eaa1b7c6354719a8e7dbdfaf55e4063a4d277d947550019b38dfb564830911057d50506136e2394c3b28945cc964967d54e3000c2181626cfb9b73efd2",
        "c39639e7d5c7fb8cdd0fd3e6a52096039437122f21c78f1679cea9d78a734c56ecbeb28654b4f18e342c331f6f7229ec4b4bc281b2d80a6eb50043f31796c88c",
        "72d081af99f8a173dcc9a0ac4eb3557405639a29084b54a40172912a2f8a395129d5536f0918e902f9e8fa6000995f4168ddc5f893011be6a0dbc9b8a1a3f5bb",
        "c11aa81e5efd24d5fc27ee586cfd8847fbb0e27601ccece5ecca0198e3c7765393bb74457c7e7a27eb9170350e1fb53857177506be3e762cc0f14d8c3afe9077",
        "c28f2150b452e6c0c424bcde6f8d72007f9310fed7f2f87de0dbb64f4479d6c1441ba66f44b2accee61609177ed340128b407ecec7c64bbe50d63d22d8627727",
        "f63d88122877ec30b8c8b00d22e89000a966426112bd44166e2f525b769ccbe9b286d437a0129130dde1a86c43e04bedb594e671d98283afe64ce331de9828fd",
        "348b0532880b88a6614a8d7408c3f913357fbb60e995c60205be9139e74998aede7f4581e42f6b52698f7fa1219708c14498067fd1e09502de83a77dd281150c",
        "5133dc8bef725359dff59792d85eaf75b7e1dcd1978b01c35b1b85fcebc63388ad99a17b6346a217dc1a9622ebd122ecf6913c4d31a6b52a695b86af00d741a0",
        "2753c4c0e98ecad806e88780ec27fccd0f5c1ab547f9e4bf1659d192c23aa2cc971b58b6802580baef8adc3b776ef7086b2545c2987f348ee3719cdef258c403",
        "b1663573ce4b9d8caefc865012f3e39714b9898a5da6ce17c25a6a47931a9ddb9bbe98adaa553beed436e89578455416c2a52a525cf2862b8d1d49a2531b7391",
        "64f58bd6bfc856f5e873b2a2956ea0eda0d6db0da39c8c7fc67c9f9feefcff3072cdf9e6ea37f69a44f0c61aa0da3693c2db5b54960c0281a088151db42b11e8",
        "0764c7be28125d9065c4b98a69d60aede703547c66a12e17e1c618994132f5ef82482c1e3fe3146cc65376cc109f0138ed9a80e49f1f3c7d610d2f2432f20605",
        "f748784398a2ff03ebeb07e155e66116a839741a336e32da71ec696001f0ad1b25cd48c69cfca7265eca1dd71904a0ce748ac4124f3571076dfa7116a9cf00e9",
        "3f0dbc0186bceb6b785ba78d2a2a013c910be157bdaffae81bb6663b1a73722f7f1228795f3ecada87cf6ef0078474af73f31eca0cc200ed975b6893f761cb6d",
        "d4762cd4599876ca75b2b8fe249944dbd27ace741fdab93616cbc6e425460feb51d4e7adcc38180e7fc47c89024a7f56191adb878dfde4ead62223f5a2610efe",
        "cd36b3d5b4c91b90fcbba79513cfee1907d8645a162afd0cd4cf4192d4a5f4c892183a8eacdb2b6b6a9d9aa8c11ac1b261b380dbee24ca468f1bfd043c58eefe",
        "98593452281661a53c48a9d8cd790826c1a1ce567738053d0bee4a91a3d5bd92eefdbabebe3204f2031ca5f781bda99ef5d8ae56e5b04a9e1ecd21b0eb05d3e1",
        "771f57dd2775ccdab55921d3e8e30ccf484d61fe1c1b9c2ae819d0fb2a12fab9be70c4a7a138da84e8280435daade5bbe66af0836a154f817fb17f3397e725a3",
        "c60897c6f828e21f16fbb5f15b323f87b6c8955eabf1d38061f707f608abdd993fac3070633e286cf8339ce295dd352df4b4b40b2f29da1dd50b3a05d079e6bb",
        "8210cd2c2d3b135c2cf07fa0d1433cd771f325d075c6469d9c7f1ba0943cd4ab09808cabf4acb9ce5bb88b498929b4b847f681ad2c490d042db2aec94214b06b",
        "1d4edfffd8fd80f7e4107840fa3aa31e32598491e4af7013c197a65b7f36dd3ac4b478456111cd4309d9243510782fa31b7c4c95fa951520d020eb7e5c36e4ef",
        "af8e6e91fab46ce4873e1a50a8ef448cc29121f7f74deef34a71ef89cc00d9274bc6c2454bbb3230d8b2ec94c62b1dec85f3593bfa30ea6f7a44d7c09465a253",
        "29fd384ed4906f2d13aa9fe7af905990938bed807f1832454a372ab412eea1f5625a1fcc9ac8343b7c67c5aba6e0b1cc4644654913692c6b39eb9187ceacd3ec",
        "a268c7885d9874a51c44dffed8ea53e94f78456e0b2ed99ff5a3924760813826d960a15edbedbb5de5226ba4b074e71b05c55b9756bb79e55c02754c2c7b6c8a",
        "0cf8545488d56a86817cd7ecb10f7116b7ea530a45b6ea497b6c72c997e09e3d0da8698f46bb006fc977c2cd3d1177463ac9057fdd1662c85d0c126443c10473",
        "b39614268fdd8781515e2cfebf89b4d5402bab10c226e6344e6b9ae000fb0d6c79cb2f3ec80e80eaeb1980d2f8698916bd2e9f747236655116649cd3ca23a837",
        "74bef092fc6f1e5dba3663a3fb003b2a5ba257496536d99f62b9d73f8f9eb3ce9ff3eec709eb883655ec9eb896b9128f2afc89cf7d1ab58a72f4a3bf034d2b4a",
        "3a988d38d75611f3ef38b8774980b33e573b6c57bee0469ba5eed9b44f29945e7347967fba2c162e1c3be7f310f2f75ee2381e7bfd6b3f0baea8d95dfb1dafb1",
        "58aedfce6f67ddc85a28c992f1c0bd0969f041e66f1ee88020a125cbfcfebcd61709c9c4eba192c15e69f020d462486019fa8dea0cd7a42921a19d2fe546d43d",
        "9347bd291473e6b4e368437b8e561e065f649a6d8ada479ad09b1999a8f26b91cf6120fd3bfe014e83f23acfa4c0ad7b3712b2c3c0733270663112ccd9285cd9",
        "b32163e7c5dbb5f51fdc11d2eac875efbbcb7e7699090a7e7ff8a8d50795af5d74d9ff98543ef8cdf89ac13d0485278756e0ef00c817745661e1d59fe38e7537",
        "1085d78307b1c4b008c57a2e7e5b234658a0a82e4ff1e4aaac72b312fda0fe27d233bc5b10e9cc17fdc7697b540c7d95eb215a19a1a0e20e1abfa126efd568c7",
        "4e5c734c7dde011d83eac2b7347b373594f92d7091b9ca34cb9c6f39bdf5a8d2f134379e16d822f6522170ccf2ddd55c84b9e6c64fc927ac4cf8dfb2a17701f2",
        "695d83bd990a1117b3d0ce06cc888027d12a054c2677fd82f0d4fbfc93575523e7991a5e35a3752e9b70ce62992e268a877744cdd435f5f130869c9a2074b338",
        "a6213743568e3b3158b9184301f3690847554c68457cb40fc9a4b8cfd8d4a118c301a07737aeda0f929c68913c5f51c80394f53bff1c3e83b2e40ca97eba9e15",
        "d444bfa2362a96df213d070e33fa841f51334e4e76866b8139e8af3bb3398be2dfaddcbc56b9146de9f68118dc5829e74b0c28d7711907b121f9161cb92b69a9",
        "142709d62e28fcccd0af97fad0f8465b971e82201dc51070faa0372aa43e92484be1c1e73ba10906d5d1853db6a4106e0a7bf9800d373d6dee2d46d62ef2a461",
    ];
    auto buf = new ubyte[hashes.length];

    for(int i = 0; i < hashes.length; ++i)
    {
        ubyte[] test;
        buf[i] = cast(ubyte)i;
        assert(blake2b(test, buf[0..i], key) == 0);
        assert(test == hexBytes(hashes[i]));
    }


    for(int step = 1; step < CONSTANT.BLOCKBYTES; ++step)
    {
        for (int i = 0; i < hashes.length; ++i)
        {
            ubyte[CONSTANT.OUTBYTES] test;
            State S;
            ubyte * p = buf.ptr;
            size_t mlen = i;

            assert(blake2bInitKey(&S, CONSTANT.OUTBYTES, &key, CONSTANT.KEYBYTES) == 0);

            while (mlen >= step) {
                assert(blake2bUpdate(&S, p, step) == 0);
                mlen -= step;
                p += step;
            }
            assert(blake2bUpdate(&S, p, mlen) == 0);
            assert(blake2bFinal(&S, &test, CONSTANT.OUTBYTES) == 0);
            assert(test == hexBytes(hashes[i]));
        }
    }

    writeln("Unit tests of \"blake2b\" have been run successfully.");
}