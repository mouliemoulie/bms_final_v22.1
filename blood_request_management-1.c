#include "blood_request_management.h"
#include "logging.h"
#include "file_management.h"
#include "file_names.h"
#include "utility.h"
#include <stdlib.h>
#include <string.h>
static bool Match(const void*d,const void*k){return((const BmsBloodRequest_t*)d)->requestId==*(const BmsRequestId_t*)k;}
static int DateCmp(const BmsDate_t*a,const BmsDate_t*b){return UtilityCompareDates(a,b);}
static bool Better(const BmsBloodRequest_t*a,const BmsBloodRequest_t*b){if(a->priority!=b->priority)return a->priority>b->priority;{int c=DateCmp(&a->requiredByDate,&b->requiredByDate);if(c!=0)return c<0;}return a->requestId<b->requestId;}
BmsStatus_t BloodRequestManagementInitialize(BmsBloodRequestContext_t*c){if(c==NULL)return BMS_STATUS_INVALID_ARGUMENT;(void)memset(c,0,sizeof(*c));if(LinkedListInitialize(&c->requests,sizeof(BmsBloodRequest_t))!=BMS_STATUS_OK)return BMS_STATUS_MEMORY_ERROR;if(HashTableInitialize(&c->requestIdIndex,BMS_HASH_BUCKET_COUNT,sizeof(BmsBloodRequest_t*),BMS_HASH_KEY_UINT32)!=BMS_STATUS_OK)return BMS_STATUS_MEMORY_ERROR;if(QueueInitialize(&c->processingQueue,BMS_REQUEST_QUEUE_CAPACITY,sizeof(BmsRequestId_t))!=BMS_STATUS_OK)return BMS_STATUS_MEMORY_ERROR;c->initialized=true;return BMS_STATUS_OK;}
BmsStatus_t BloodRequestManagementLoad(BmsBloodRequestContext_t*c){bool e=false;uint32_t n=0U,i;BmsBloodRequest_t*a;BmsStatus_t s;if((c==NULL)||!c->initialized)return BMS_STATUS_NOT_INITIALIZED;(void)FileManagementFileExists(BMS_REQUESTS_FILE,&e);if(!e)return BMS_STATUS_OK;s=FileManagementGetRecordCount(BMS_REQUESTS_FILE,sizeof(*a),&n);if(s!=BMS_STATUS_OK)return s;if(n==0U)return BMS_STATUS_OK;a=(BmsBloodRequest_t*)calloc(n,sizeof(*a));if(a==NULL)return BMS_STATUS_MEMORY_ERROR;s=FileManagementReadRecords(BMS_REQUESTS_FILE,a,n,&n,sizeof(*a));for(i=0U;(s==BMS_STATUS_OK)&&(i<n);++i){s=LinkedListInsertBack(&c->requests,&a[i]);}free(a);return s;}
BmsStatus_t BloodRequestManagementSave(const BmsBloodRequestContext_t *context)
{
    BmsBloodRequest_t *records = NULL;
    const BmsLinkedListNode_t *node = NULL;
    uint32_t index = 0U;
    BmsStatus_t status;

    if ((context == NULL) || (!context->initialized))
    {
        return BMS_STATUS_NOT_INITIALIZED;
    }

    if (context->requests.count == 0U)
    {
        return FileManagementWriteRecords(BMS_REQUESTS_FILE, NULL, 0U,
                                          sizeof(BmsBloodRequest_t));
    }

    records = (BmsBloodRequest_t *)calloc(context->requests.count, sizeof(*records));
    if (records == NULL)
    {
        return BMS_STATUS_MEMORY_ERROR;
    }

    for (node = context->requests.head; node != NULL; node = node->next)
    {
        if (node->data == NULL)
        {
            free(records);
            return BMS_STATUS_INVALID_DATA;
        }
        records[index] = *(const BmsBloodRequest_t *)node->data;
        ++index;
    }

    status = FileManagementWriteRecords(BMS_REQUESTS_FILE, records, index,
                                        sizeof(*records));
    free(records);
    return status;
}
BmsStatus_t BloodRequestManagementCreate(BmsBloodRequestContext_t *c,
                                             const BmsBloodRequest_t *r)
{
    void *found = NULL;
    BmsStatus_t status;

    if ((c == NULL) || (r == NULL))
    {
        return BMS_STATUS_INVALID_ARGUMENT;
    }

    if (LinkedListFind(&c->requests, Match, &r->requestId, &found) == BMS_STATUS_OK)
    {
        BMS_LOG_WARNING("REQUEST",
                        "Duplicate request rejected: requestId=%u",
                        (unsigned int)r->requestId);
        return BMS_STATUS_ALREADY_EXISTS;
    }

    status = LinkedListInsertBack(&c->requests, r);
    if (status == BMS_STATUS_OK)
    {
        BMS_LOG_INFO("REQUEST",
                     "Request created: requestId=%u group=%s units=%u priority=%u",
                     (unsigned int)r->requestId,
                     UtilityBloodGroupToString(r->bloodGroup),
                     (unsigned int)r->requestedUnits,
                     (unsigned int)r->priority);
    }
    else
    {
        BMS_LOG_ERROR("REQUEST",
                      "Request creation failed: requestId=%u status=%u",
                      (unsigned int)r->requestId,
                      (unsigned int)status);
    }

    return status;
}
BmsStatus_t BloodRequestManagementSearchById(const BmsBloodRequestContext_t*c,BmsRequestId_t id,BmsBloodRequest_t*r){void*f=NULL;BmsStatus_t s;if((c==NULL)||(r==NULL))return BMS_STATUS_INVALID_ARGUMENT;s=LinkedListFind(&c->requests,Match,&id,&f);if(s==BMS_STATUS_OK)*r=*(BmsBloodRequest_t*)f;return s;}
static BmsStatus_t SetStatus(BmsBloodRequestContext_t *c,
                              BmsRequestId_t id,
                              BmsRequestStatus_t requestStatus)
{
    void *found = NULL;
    BmsStatus_t status = LinkedListFind(&c->requests, Match, &id, &found);

    if (status == BMS_STATUS_OK)
    {
        ((BmsBloodRequest_t *)found)->status = requestStatus;
        BMS_LOG_INFO("REQUEST",
                     "Request status changed: requestId=%u status=%u",
                     (unsigned int)id,
                     (unsigned int)requestStatus);
    }
    else
    {
        BMS_LOG_WARNING("REQUEST",
                        "Request status change failed: requestId=%u status=%u",
                        (unsigned int)id,
                        (unsigned int)status);
    }

    return status;
}
BmsStatus_t BloodRequestManagementApprove(BmsBloodRequestContext_t*c,BmsRequestId_t id){return(c==NULL)?BMS_STATUS_INVALID_ARGUMENT:SetStatus(c,id,BMS_REQUEST_STATUS_APPROVED);} BmsStatus_t BloodRequestManagementReject(BmsBloodRequestContext_t*c,BmsRequestId_t id){return(c==NULL)?BMS_STATUS_INVALID_ARGUMENT:SetStatus(c,id,BMS_REQUEST_STATUS_REJECTED);}
BmsStatus_t BloodRequestManagementFulfill(BmsBloodRequestContext_t *c,
                                             BmsInventoryContext_t *i,
                                             BmsRequestId_t id)
{
    void *found = NULL;
    BmsLinkedListNode_t *node;
    BmsBloodRequest_t *request;
    uint32_t need;
    uint32_t total = 0U;

    if ((c == NULL) || (i == NULL))
    {
        return BMS_STATUS_INVALID_ARGUMENT;
    }

    if ((!c->initialized) || (!i->initialized))
    {
        return BMS_STATUS_NOT_INITIALIZED;
    }

    if (LinkedListFind(&c->requests, Match, &id, &found) != BMS_STATUS_OK)
    {
        return BMS_STATUS_NOT_FOUND;
    }

    if (found == NULL)
    {
        return BMS_STATUS_INVALID_DATA;
    }

    request = (BmsBloodRequest_t *)found;

    /*
     * A fulfilled count greater than the requested count is invalid data.
     * Without this check, the unsigned subtraction below would wrap and
     * produce a very large inventory requirement.
     */
    if (request->fulfilledUnits > request->requestedUnits)
    {
        return BMS_STATUS_INVALID_DATA;
    }

    need = request->requestedUnits - request->fulfilledUnits;

    for (node = i->inventory.head; node != NULL; node = node->next)
    {
        const BmsBloodInventory_t *stock;

        if (node->data == NULL)
        {
            return BMS_STATUS_INVALID_DATA;
        }

        stock = (const BmsBloodInventory_t *)node->data;

        if ((stock->bloodGroup == request->bloodGroup) &&
            stock->isAvailable)
        {
            total += stock->units;
        }
    }

    if (total < need)
    {
        BMS_LOG_WARNING("REQUEST",
                        "Insufficient inventory: requestId=%u required=%u available=%u",
                        (unsigned int)id,
                        (unsigned int)need,
                        (unsigned int)total);
        return BMS_STATUS_INSUFFICIENT_STOCK;
    }

    for (node = i->inventory.head;
         (node != NULL) && (need > 0U);
         node = node->next)
    {
        BmsBloodInventory_t *stock;
        uint32_t take;

        if (node->data == NULL)
        {
            return BMS_STATUS_INVALID_DATA;
        }

        stock = (BmsBloodInventory_t *)node->data;

        if ((stock->bloodGroup == request->bloodGroup) &&
            stock->isAvailable)
        {
            take = (stock->units < need) ? stock->units : need;
            stock->units -= take;
            need -= take;
            stock->isAvailable = (stock->units > 0U);
        }
    }

    request->fulfilledUnits = request->requestedUnits;
    request->status = BMS_REQUEST_STATUS_FULFILLED;

    BMS_LOG_INFO("REQUEST",
                 "Request fulfilled: requestId=%u units=%u",
                 (unsigned int)id,
                 (unsigned int)request->fulfilledUnits);
    return BMS_STATUS_OK;
}
BmsStatus_t BloodRequestManagementProcessNext(
    BmsBloodRequestContext_t *context,
    BmsInventoryContext_t *inventory,
    BmsBloodRequest_t *outRequest)
{
    const BmsLinkedListNode_t *node;
    BmsBloodRequest_t *best = NULL;
    BmsStatus_t status;

    if ((context == NULL) || (inventory == NULL) || (outRequest == NULL))
    {
        return BMS_STATUS_INVALID_ARGUMENT;
    }

    /*
     * Only PENDING requests are claimable.
     * FULFILLED/REJECTED/CANCELLED requests can never be processed again.
     */
    for (node = context->requests.head; node != NULL; node = node->next)
    {
        BmsBloodRequest_t *request = (BmsBloodRequest_t *)node->data;

        if ((request != NULL) &&
            (request->status == BMS_REQUEST_STATUS_PENDING))
        {
            if ((best == NULL) || Better(request, best))
            {
                best = request;
            }
        }
    }

    if (best == NULL)
    {
        BMS_LOG_DEBUG("REQUEST", "No pending request available for processing");
        return BMS_STATUS_QUEUE_EMPTY;
    }

    best->status = BMS_REQUEST_STATUS_PROCESSING;
    BMS_LOG_INFO("REQUEST",
                 "Processing next request: requestId=%u priority=%u",
                 (unsigned int)best->requestId,
                 (unsigned int)best->priority);

    status = BloodRequestManagementFulfill(context, inventory, best->requestId);

    /*
     * If stock is not currently sufficient, return the request to PENDING.
     * This prevents a stale PROCESSING state while still allowing a later retry.
     */
    if (status == BMS_STATUS_INSUFFICIENT_STOCK)
    {
        best->status = BMS_REQUEST_STATUS_PENDING;
        BMS_LOG_INFO("REQUEST",
                     "Request returned to pending: requestId=%u",
                     (unsigned int)best->requestId);
    }

    *outRequest = *best;
    return status;
}
BmsStatus_t BloodRequestManagementTraverse(const BmsBloodRequestContext_t*c,BmsRequestVisitor_t v,void*x){const BmsLinkedListNode_t*n;if((c==NULL)||(v==NULL))return BMS_STATUS_INVALID_ARGUMENT;for(n=c->requests.head;n;n=n->next){BmsStatus_t s=v((const BmsBloodRequest_t*)n->data,x);if(s!=BMS_STATUS_OK)return s;}return BMS_STATUS_OK;}
void BloodRequestManagementDeinitialize(BmsBloodRequestContext_t*c){if(c==NULL)return;LinkedListClear(&c->requests);HashTableDeinitialize(&c->requestIdIndex);QueueDeinitialize(&c->processingQueue);(void)memset(c,0,sizeof(*c));}
