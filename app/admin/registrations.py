"""Explicit `admin.site.register(...)` calls (these run after the site swap, so they go to the custom site)."""
from ..models import *
from django.contrib import admin
from django.contrib.auth.models import User, Group
from django.contrib.admin.models import LogEntry
from django.contrib.auth.admin import UserAdmin, GroupAdmin
from .auth_admin import LogEntryAdmin
from .catalog import InventoryAdmin, MonthlyClosingAdmin, StockBatchAdmin
from .core import CompanyInfoAdmin, LicenseAdmin, TrainingStepAdmin, TrainingTopicAdmin
from .purchasing import PurchaseAdmin, PurchaseItemAdmin, PurchaseRetrnAdmin, PurchaseRetrnItemAdmin
from .sales import CustomerAdmin, SaleAdmin, SaleItemAdmin, SaleRangeReportAdmin, SaleRetrnAdmin, SaleRetrnItemAdmin


# ============================================
# REGISTER ALL MODELS
# ============================================
admin.site.register(CompanyInfo, CompanyInfoAdmin)


admin.site.register(Brand)


@admin.action(description="AI se master category dobara chunein (manual wali bhi)")
def reclassify_categories(modeladmin, request, queryset):
    from ..category_ai import assign_master
    n = 0
    for c in queryset:
        if assign_master(c, force=True):
            n += 1
    modeladmin.message_user(request, f"{n} categories ko master mil gaya.")


class CategoryAdmin(admin.ModelAdmin):
    list_display = ('name', 'master', 'master_source', 'min_margin_percent')
    list_filter = ('master', 'master_source')
    search_fields = ('name',)
    fields = ('name', 'master', 'min_margin_percent')
    actions = [reclassify_categories]

    def save_model(self, request, obj, form, change):
        if 'master' in form.changed_data and obj.master_id:
            obj.master_source = 'manual'          # admin ka chuna hua AI kabhi nahi badlegi
        super().save_model(request, obj, form, change)


class MasterCategoryAdmin(admin.ModelAdmin):
    list_display = ('name', 'icon', 'sort_order', 'is_active')
    list_editable = ('icon', 'sort_order', 'is_active')
    search_fields = ('name',)


admin.site.register(MasterCategory, MasterCategoryAdmin)


admin.site.register(Category, CategoryAdmin)


admin.site.register(Types)


admin.site.register(Location)


admin.site.register(Unit)


admin.site.register(Purchase, PurchaseAdmin)


admin.site.register(Customer, CustomerAdmin)


admin.site.register(Sale, SaleAdmin)


admin.site.register(Inventory, InventoryAdmin)


admin.site.register(StockBatch, StockBatchAdmin)


admin.site.register(PurchaseItem, PurchaseItemAdmin)


admin.site.register(SaleItem, SaleItemAdmin)


admin.site.register(MonthlyClosing, MonthlyClosingAdmin)


admin.site.register(PurchaseRetrn, PurchaseRetrnAdmin)


admin.site.register(PurchaseRetrnItem, PurchaseRetrnItemAdmin)


admin.site.register(SaleRetrn, SaleRetrnAdmin)


admin.site.register(SaleRetrnItem, SaleRetrnItemAdmin)


admin.site.register(LogEntry, LogEntryAdmin)


admin.site.register(License, LicenseAdmin)


admin.site.register(User, UserAdmin)


admin.site.register(Group, GroupAdmin)


admin.site.register(TrainingStep, TrainingStepAdmin)


admin.site.register(TrainingTopic, TrainingTopicAdmin)


admin.site.register(SaleRangeReport, SaleRangeReportAdmin)
