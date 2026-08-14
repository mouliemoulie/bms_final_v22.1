/** @file donation_management.c @brief Donation management implementation. */
#include "donation_management.h"
#include "logging.h"
#include "common_validation.h"
#include "file_management.h"
#include "file_names.h"
#include <stdlib.h>
#include <string.h>
static bool Match(const void*d,const void*k){return((const BmsDonation_t*)d)->donationId==*(const BmsDonationId_t*)k;}
BmsStatus_t DonationManagementInitialize(BmsDonationContext_t*c){if(c==NULL)return BMS_STATUS_INVALID_ARGUMENT;(void)memset(c,0,sizeof(*c));LinkedListInitialize(&c->donations,sizeof(BmsDonation_t));HashTableInitialize(&c->donationIdIndex,BMS_HASH_BUCKET_COUNT,sizeof(BmsDonation_t*),BMS_HASH_KEY_UINT32);c->initialized=true;return BMS_STATUS_OK;}
BmsStatus_t DonationManagementLoad(BmsDonationContext_t*c){bool exists=false;uint32_t count=0U,i=0U;BmsDonation_t*a=NULL;BmsStatus_t st;if((c==NULL)||!c->initialized)return BMS_STATUS_NOT_INITIALIZED;(void)FileManagementFileExists(BMS_DONATIONS_FILE,&exists);if(!exists)return BMS_STATUS_OK;st=FileManagementGetRecordCount(BMS_DONATIONS_FILE,sizeof(BmsDonation_t),&count);if(st!=BMS_STATUS_OK)return st;if(count==0U)return BMS_STATUS_OK;a=(BmsDonation_t*)calloc(count,sizeof(*a));if(a==NULL)return BMS_STATUS_MEMORY_ERROR;st=FileManagementReadRecords(BMS_DONATIONS_FILE,a,count,&count,sizeof(*a));for(i=0U;(st==BMS_STATUS_OK)&&(i<count);++i)st=LinkedListInsertBack(&c->donations,&a[i]);free(a);return st;}
BmsStatus_t DonationManagementSave(const BmsDonationContext_t *context)
{
    BmsDonation_t *records = NULL;
    const BmsLinkedListNode_t *node = NULL;
    uint32_t index = 0U;
    BmsStatus_t status;

    if ((context == NULL) || (!context->initialized))
    {
        return BMS_STATUS_NOT_INITIALIZED;
    }

    if (context->donations.count == 0U)
    {
        return FileManagementWriteRecords(BMS_DONATIONS_FILE, NULL, 0U,
                                          sizeof(BmsDonation_t));
    }

    records = (BmsDonation_t *)calloc(context->donations.count, sizeof(*records));
    if (records == NULL)
    {
        return BMS_STATUS_MEMORY_ERROR;
    }

    for (node = context->donations.head; node != NULL; node = node->next)
    {
        if (node->data == NULL)
        {
            free(records);
            return BMS_STATUS_INVALID_DATA;
        }
        records[index] = *(const BmsDonation_t *)node->data;
        ++index;
    }

    status = FileManagementWriteRecords(BMS_DONATIONS_FILE, records, index,
                                        sizeof(*records));
    free(records);
    return status;
}
BmsStatus_t DonationManagementRecord(BmsDonationContext_t *context,
                                     BmsDonorContext_t *donorContext,
                                     BmsInventoryContext_t *inventoryContext,
                                     const BmsDonation_t *donation)
{
    BmsBloodInventory_t stock;
    BmsDonor_t donor;
    BmsStatus_t status;

    if ((context == NULL) || (donorContext == NULL) ||
        (inventoryContext == NULL) || (donation == NULL))
    {
        return BMS_STATUS_INVALID_ARGUMENT;
    }

    status = DonorManagementSearchById(donorContext,
                                       donation->donorId,
                                       &donor);
    if (status != BMS_STATUS_OK)
    {
        return status;
    }

    (void)memset(&stock, 0, sizeof(stock));
    stock.bloodId = donation->donationId;
    stock.bloodGroup = donation->bloodGroup;
    stock.units = donation->units;
    stock.collectionDate = donation->donationDate;
    stock.isAvailable = true;

    status = BmsDateAddDays(&stock.collectionDate,
                            BMS_RBC_SHELF_LIFE_DAYS,
                            &stock.expiryDate);
    if (status != BMS_STATUS_OK)
    {
        BMS_LOG_ERROR("DONATION",
                      "Expiry calculation failed: donationId=%u status=%u",
                      (unsigned int)donation->donationId,
                      (unsigned int)status);
        return status;
    }

    status = LinkedListInsertBack(&context->donations, donation);
    if (status != BMS_STATUS_OK)
    {
        BMS_LOG_ERROR("DONATION",
                      "Donation record insertion failed: donationId=%u status=%u",
                      (unsigned int)donation->donationId,
                      (unsigned int)status);
        return status;
    }

    status = BloodInventoryAddStock(inventoryContext, &stock);
    if (status == BMS_STATUS_OK)
    {
        BMS_LOG_INFO("DONATION",
                     "Donation recorded: donationId=%u donorId=%u group=%s units=%u",
                     (unsigned int)donation->donationId,
                     (unsigned int)donation->donorId,
                     BloodGroupToString(donation->bloodGroup),
                     (unsigned int)donation->units);
    }
    else
    {
        BMS_LOG_ERROR("DONATION",
                      "Inventory creation failed for donationId=%u status=%u",
                      (unsigned int)donation->donationId,
                      (unsigned int)status);
    }

    return status;
}
BmsStatus_t DonationManagementSearchById(const BmsDonationContext_t*c,BmsDonationId_t id,BmsDonation_t*d){void*f=NULL;BmsStatus_t s;if((c==NULL)||(d==NULL))return BMS_STATUS_INVALID_ARGUMENT;s=LinkedListFind(&c->donations,Match,&id,&f);if(s==BMS_STATUS_OK)*d=*(BmsDonation_t*)f;return s;}
BmsStatus_t DonationManagementFindByDonor(const BmsDonationContext_t*c,BmsDonorId_t id,BmsDonationVisitor_t v,void*x){const BmsLinkedListNode_t*n;if((c==NULL)||(v==NULL))return BMS_STATUS_INVALID_ARGUMENT;for(n=c->donations.head;n;n=n->next)if(((BmsDonation_t*)n->data)->donorId==id){BmsStatus_t s=v(n->data,x);if(s!=BMS_STATUS_OK)return s;}return BMS_STATUS_OK;}
BmsStatus_t DonationManagementTraverse(const BmsDonationContext_t*c,BmsDonationVisitor_t v,void*x){const BmsLinkedListNode_t*n;if((c==NULL)||(v==NULL))return BMS_STATUS_INVALID_ARGUMENT;for(n=c->donations.head;n;n=n->next){BmsStatus_t s=v(n->data,x);if(s!=BMS_STATUS_OK)return s;}return BMS_STATUS_OK;}
void DonationManagementDeinitialize(BmsDonationContext_t*c){if(c==NULL)return;LinkedListClear(&c->donations);HashTableDeinitialize(&c->donationIdIndex);(void)memset(c,0,sizeof(*c));}
